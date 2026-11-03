#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dwmapi.h>
#include <d3d11_4.h>
#include <d2d1_1.h>
#include <DispatcherQueue.h>
#include <roapi.h>
#include <UIAutomation.h>
#include <windows.ui.composition.interop.h>
#include <windows.graphics.interop.h>
#include <windows.graphics.effects.interop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.System.h>
#include <winrt/Windows.Graphics.h>
#include <winrt/Windows.Graphics.Effects.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/Windows.UI.Composition.h>
#include <winrt/Windows.UI.Composition.Desktop.h>
#include <atomic>
#include <algorithm>
#include <cmath>
#include <vector>
#include <memory>

using namespace winrt;
using namespace winrt::Windows::Foundation;
using namespace winrt::Windows::Graphics;
using namespace winrt::Windows::Graphics::Effects;
using namespace winrt::Windows::UI::Composition;
using namespace winrt::Windows::UI::Composition::Desktop;

namespace {
constexpr UINT RemovedMessage = WM_APP + 417;
constexpr wchar_t WindowClass[] = L"CodexPacer.CompositionSurface.v1";
// HostBackdropBrush has no dark-material wash of its own. Keep the lightest
// wallpaper dark enough for Pacer's existing secondary text.
constexpr float TintOpacity = .72f;

struct GeometrySource : implements<GeometrySource, IGeometrySource2D, ABI::Windows::Graphics::IGeometrySource2DInterop> {
    com_ptr<ID2D1PathGeometry> geometry;
    explicit GeometrySource(com_ptr<ID2D1PathGeometry> value) : geometry(std::move(value)) {}
    HRESULT __stdcall GetGeometry(ID2D1Geometry** value) noexcept override { return geometry->QueryInterface(IID_PPV_ARGS(value)); }
    HRESULT __stdcall TryGetGeometryUsingFactory(ID2D1Factory* factory, ID2D1Geometry** value) noexcept override {
        try {
            com_ptr<ID2D1PathGeometry> copy; check_hresult(factory->CreatePathGeometry(copy.put()));
            com_ptr<ID2D1GeometrySink> sink; check_hresult(copy->Open(sink.put()));
            check_hresult(geometry->Stream(sink.get())); check_hresult(sink->Close());
            return copy->QueryInterface(IID_PPV_ARGS(value));
        } catch (...) { return to_hresult(); }
    }
};

struct Blur : implements<Blur, IGraphicsEffect, IGraphicsEffectSource, ABI::Windows::Graphics::Effects::IGraphicsEffectD2D1Interop> {
    IGraphicsEffectSource source;
    float radius;
    Blur(IGraphicsEffectSource const& value, float amount) : source(value), radius(amount) {}
    hstring Name() const { return L"BackdropBlur"; }
    void Name(hstring const&) const {}
    HRESULT __stdcall GetEffectId(GUID* value) noexcept override { *value = CLSID_D2D1GaussianBlur; return S_OK; }
    HRESULT __stdcall GetNamedPropertyMapping(LPCWSTR, UINT*, ABI::Windows::Graphics::Effects::GRAPHICS_EFFECT_PROPERTY_MAPPING*) noexcept override { return E_INVALIDARG; }
    HRESULT __stdcall GetPropertyCount(UINT* count) noexcept override { *count = 3; return S_OK; }
    HRESULT __stdcall GetProperty(UINT index, ABI::Windows::Foundation::IPropertyValue** value) noexcept override {
        try {
            IPropertyValue property{nullptr};
            if (index == 0) property = PropertyValue::CreateSingle(radius).as<IPropertyValue>();
            else if (index < 3) property = PropertyValue::CreateUInt32(1).as<IPropertyValue>();
            else return E_INVALIDARG;
            *value = reinterpret_cast<ABI::Windows::Foundation::IPropertyValue*>(detach_abi(property)); return S_OK;
        } catch (...) { return to_hresult(); }
    }
    HRESULT __stdcall GetSource(UINT index, ABI::Windows::Graphics::Effects::IGraphicsEffectSource** value) noexcept override {
        if (index != 0) return E_INVALIDARG;
        return source.as<ABI::Windows::Graphics::Effects::IGraphicsEffectSource>().copy_to(value), S_OK;
    }
    HRESULT __stdcall GetSourceCount(UINT* count) noexcept override { *count = 1; return S_OK; }
};

// WPF pumps this thread's Win32 queue. Keep its DispatcherQueue for the UI
// thread's lifetime, including when all surface HWNDs have been closed.
void EnsureQueue() {
    static thread_local bool ready = [] {
        check_hresult(RoInitialize(RO_INIT_SINGLETHREADED));
        if (!winrt::Windows::System::DispatcherQueue::GetForCurrentThread()) {
            struct QueueLifetime { winrt::Windows::System::DispatcherQueueController controller{nullptr}; };
            auto lifetime = std::make_unique<QueueLifetime>();
            DispatcherQueueOptions options{sizeof(options), DQTYPE_THREAD_CURRENT, DQTAT_COM_NONE};
            check_hresult(CreateDispatcherQueueController(options,
                reinterpret_cast<ABI::Windows::System::IDispatcherQueueController**>(put_abi(lifetime->controller))));
            (void)lifetime.release();
        }
        return true;
    }();
    (void)ready;
}

struct Surface;
LRESULT CALLBACK WindowProc(HWND, UINT, WPARAM, LPARAM);

// Decoration is excluded from UIA's control/content views. The existing WPF
// HWND above it owns the named controls and expansion/action providers.
struct DecorationProvider : implements<DecorationProvider, IRawElementProviderSimple> {
    HWND window;
    explicit DecorationProvider(HWND value) : window(value) {}
    HRESULT __stdcall get_ProviderOptions(ProviderOptions* value) noexcept override { *value = ProviderOptions_ServerSideProvider; return S_OK; }
    HRESULT __stdcall GetPatternProvider(PATTERNID, IUnknown** value) noexcept override { *value = nullptr; return S_OK; }
    HRESULT __stdcall GetPropertyValue(PROPERTYID property, VARIANT* value) noexcept override {
        *value = {};
        if (property == UIA_IsControlElementPropertyId || property == UIA_IsContentElementPropertyId || property == UIA_IsKeyboardFocusablePropertyId) {
            value->vt = VT_BOOL; value->boolVal = VARIANT_FALSE;
        }
        return S_OK;
    }
    HRESULT __stdcall get_HostRawElementProvider(IRawElementProviderSimple** value) noexcept override { return UiaHostProviderFromHwnd(window, value); }
};

struct Surface {
    HWND content{}, window{};
    UINT notification{};
    DWORD thread{GetCurrentThreadId()};
    std::atomic_bool removed{false};
    Compositor compositor{nullptr};
    DesktopWindowTarget target{nullptr};
    ContainerVisual root{nullptr};
    SpriteVisual backdrop{nullptr}, brightness{nullptr}, tint{nullptr}, noise{nullptr};
    CompositionGraphicsDevice graphics{nullptr};
    CompositionDrawingSurface grain{nullptr};
    com_ptr<ID2D1Factory> factory;
    com_ptr<ID3D11Device> device;
    com_ptr<ID3D11Device4> removalDevice;
    HANDLE removalEvent{};
    PTP_WAIT removalWait{};
    DWORD removalCookie{};
    bool removalRegistered{};
    float scale{};
    bool solid{};

    Surface(HWND owner, UINT message) : content(owner), notification(message) {
        DWORD process{};
        if (!IsWindow(content) || GetWindowThreadProcessId(content, &process) != thread || process != GetCurrentProcessId())
            throw hresult_invalid_argument();
    }
    void Initialize() {
        EnsureQueue();
        HMODULE module{};
        check_bool(GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            reinterpret_cast<LPCWSTR>(&WindowProc), &module));
        WNDCLASSEXW kind{}; kind.cbSize = sizeof(kind); kind.lpfnWndProc = WindowProc; kind.hInstance = module; kind.lpszClassName = WindowClass;
        if (!RegisterClassExW(&kind) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) throw_last_error();
        window = CreateWindowExW(WS_EX_NOREDIRECTIONBITMAP | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TOPMOST,
            WindowClass, L"", WS_POPUP, 0, 0, 1, 1, nullptr, nullptr, module, this);
        if (!window) throw_last_error();
        // The material never owns focus or input; the layered WPF window above
        // it retains the actual controls and accessibility providers.
        EnableWindow(window, FALSE);
        BOOL allow = TRUE; check_hresult(DwmSetWindowAttribute(window, 17, &allow, sizeof(allow)));
        DWORD square = 1; (void)DwmSetWindowAttribute(window, 33, &square, sizeof(square));
        compositor = Compositor();
        check_hresult(compositor.as<ABI::Windows::UI::Composition::Desktop::ICompositorDesktopInterop>()->CreateDesktopWindowTarget(window, TRUE,
            reinterpret_cast<ABI::Windows::UI::Composition::Desktop::IDesktopWindowTarget**>(put_abi(target))));
        root = compositor.CreateContainerVisual(); target.Root(root);
        check_hresult(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, factory.put()));
        com_ptr<ID3D11DeviceContext> context;
        check_hresult(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            nullptr, 0, D3D11_SDK_VERSION, device.put(), nullptr, context.put()));
        com_ptr<ID2D1Device> drawingDevice; check_hresult(D2D1CreateDevice(device.as<IDXGIDevice>().get(), nullptr, drawingDevice.put()));
        check_hresult(compositor.as<ABI::Windows::UI::Composition::ICompositorInterop>()->CreateGraphicsDevice(drawingDevice.get(),
            reinterpret_cast<ABI::Windows::UI::Composition::ICompositionGraphicsDevice**>(put_abi(graphics))));
        backdrop = Layer(); brightness = Layer(); tint = Layer(); noise = Layer();
        brightness.Brush(compositor.CreateColorBrush({255, 255, 255, 255})); brightness.Opacity(.025f);
        tint.Brush(compositor.CreateColorBrush({255, 11, 12, 14})); tint.Opacity(TintOpacity);
        removalDevice = device.as<ID3D11Device4>();
        removalEvent = CreateEventW(nullptr, FALSE, FALSE, nullptr); check_bool(removalEvent != nullptr);
        check_hresult(removalDevice->RegisterDeviceRemovedEvent(removalEvent, &removalCookie));
        removalRegistered = true;
        removalWait = CreateThreadpoolWait([](PTP_CALLBACK_INSTANCE, void* contextValue, PTP_WAIT, TP_WAIT_RESULT) {
            auto self = static_cast<Surface*>(contextValue); self->removed = true;
            PostMessageW(self->window, RemovedMessage, 0, 0);
        }, this, nullptr);
        check_bool(removalWait != nullptr); SetThreadpoolWait(removalWait, removalEvent, nullptr);
    }
    SpriteVisual Layer() {
        auto value = compositor.CreateSpriteVisual(); root.Children().InsertAtTop(value); return value;
    }
    void Grain() {
        if (grain) return;
        // A fixed texture is retained across spring frames. Resizing the island
        // must not repaint thousands of noise dots on every frame.
        constexpr int width = 512, height = 512;
        grain = graphics.CreateDrawingSurface({static_cast<float>(width), static_cast<float>(height)},
            winrt::Windows::Graphics::DirectX::DirectXPixelFormat::B8G8R8A8UIntNormalized,
            winrt::Windows::Graphics::DirectX::DirectXAlphaMode::Premultiplied);
        auto interop = grain.as<ABI::Windows::UI::Composition::ICompositionDrawingSurfaceInterop>();
        com_ptr<ID2D1DeviceContext> dc; POINT offset{};
        check_hresult(interop->BeginDraw(nullptr, __uuidof(ID2D1DeviceContext), dc.put_void(), &offset));
        struct EndDrawing {
            ABI::Windows::UI::Composition::ICompositionDrawingSurfaceInterop* surface;
            bool pending{true};
            ~EndDrawing() { if (pending) (void)surface->EndDraw(); }
        } end{interop.get()};
        dc->SetTransform(D2D1::Matrix3x2F::Translation(static_cast<float>(offset.x), static_cast<float>(offset.y)));
        dc->Clear(D2D1::ColorF(0, 0));
        com_ptr<ID2D1SolidColorBrush> brush; check_hresult(dc->CreateSolidColorBrush(D2D1::ColorF(1, 1, 1, .02f), brush.put()));
        unsigned state = 42;
        for (int y = 0; y < height; y += 2) for (int x = 0; x < width; x += 2) {
            state = state * 1664525 + 1013904223;
            if ((state >> 28) < 5) dc->FillRectangle(D2D1::RectF(static_cast<float>(x), static_cast<float>(y), static_cast<float>(x + 1), static_cast<float>(y + 1)), brush.get());
        }
        HRESULT drawn = interop->EndDraw(); end.pending = false; check_hresult(drawn);
        noise.Brush(compositor.CreateSurfaceBrush(grain));
    }
    void Solid() {
        if (!compositor || !backdrop) return;
        solid = true;
        backdrop.Brush(compositor.CreateColorBrush({255, 11, 12, 14})); brightness.Opacity(0); tint.Opacity(0); noise.Opacity(0);
    }
    void Update(int x, int y, int width, int height, double const* values, int count, float dpiScale, bool show) {
        if (GetCurrentThreadId() != thread || width < 1 || height < 1 || width > 16384 || height > 16384 ||
            !values || count < 3 || count > 2048 || !std::isfinite(dpiScale) || dpiScale < .5f || dpiScale > 8) throw hresult_invalid_argument();
        if (removed) throw hresult_error(DXGI_ERROR_DEVICE_REMOVED);
        check_hresult(device->GetDeviceRemovedReason());
        std::vector<D2D1_POINT_2F> points; std::vector<POINT> region; points.reserve(count); region.reserve(count);
        for (int i = 0; i < count; i++) {
            double px = values[i * 2], py = values[i * 2 + 1];
            if (!std::isfinite(px) || !std::isfinite(py) || std::abs(px) > 32768 || std::abs(py) > 32768) throw hresult_invalid_argument();
            points.push_back({static_cast<float>(px), static_cast<float>(py)});
            region.push_back({static_cast<LONG>(std::lround(px)), static_cast<LONG>(std::lround(py))});
        }
        if (solid || scale != dpiScale) {
            auto parameter = CompositionEffectSourceParameter(L"Backdrop");
            auto effect = compositor.CreateEffectFactory(make<Blur>(parameter, 18 * dpiScale)).CreateBrush();
            effect.SetSourceParameter(L"Backdrop", compositor.CreateHostBackdropBrush()); backdrop.Brush(effect); scale = dpiScale;
            brightness.Opacity(.025f); tint.Opacity(TintOpacity); noise.Opacity(1); solid = false;
        }
        winrt::Windows::Foundation::Numerics::float2 size{static_cast<float>(width), static_cast<float>(height)};
        root.Size(size); backdrop.Size(size); brightness.Size(size); tint.Size(size); noise.Size(size); Grain();
        com_ptr<ID2D1PathGeometry> path; check_hresult(factory->CreatePathGeometry(path.put()));
        com_ptr<ID2D1GeometrySink> sink; check_hresult(path->Open(sink.put()));
        sink->BeginFigure(points.front(), D2D1_FIGURE_BEGIN_FILLED); sink->AddLines(points.data() + 1, static_cast<UINT32>(points.size() - 1));
        sink->EndFigure(D2D1_FIGURE_END_CLOSED); check_hresult(sink->Close());
        auto geometry = compositor.CreatePathGeometry(CompositionPath(make<GeometrySource>(path)));
        root.Clip(compositor.CreateGeometricClip(geometry));
        HRGN input = CreatePolygonRgn(region.data(), static_cast<int>(region.size()), WINDING);
        check_bool(input != nullptr);
        if (!SetWindowRgn(window, input, FALSE)) { DeleteObject(input); throw_last_error(); }
        // WPF can present its layered bitmap a frame later than Composition.
        // The identical native region bounds both visuals and input immediately,
        // including when the displayed WPF bitmap still contains an older size.
        HRGN contentClip = CreatePolygonRgn(region.data(), static_cast<int>(region.size()), WINDING);
        check_bool(contentClip != nullptr);
        if (!SetWindowRgn(content, contentClip, FALSE)) { DeleteObject(contentClip); throw_last_error(); }
        if (show && IsWindowVisible(content)) {
            check_bool(SetWindowPos(window, content, x, y, width, height, SWP_NOACTIVATE | SWP_SHOWWINDOW));
        } else ShowWindow(window, SW_HIDE);
    }
    void Close() noexcept {
        if (removalWait) { SetThreadpoolWait(removalWait, nullptr, nullptr); WaitForThreadpoolWaitCallbacks(removalWait, TRUE); CloseThreadpoolWait(removalWait); removalWait = nullptr; }
        if (removalDevice && removalRegistered) { removalDevice->UnregisterDeviceRemoved(removalCookie); removalRegistered = false; }
        if (removalEvent) { CloseHandle(removalEvent); removalEvent = nullptr; }
        try { if (target) target.Root(nullptr); if (compositor) compositor.Close(); } catch (...) {}
        if (IsWindow(content)) (void)SetWindowRgn(content, nullptr, FALSE);
        if (window) { DestroyWindow(window); window = nullptr; }
    }
    ~Surface() { Close(); }
};

LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    if (message == WM_NCCREATE) SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(reinterpret_cast<CREATESTRUCTW*>(lparam)->lpCreateParams));
    auto self = reinterpret_cast<Surface*>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCALCSIZE) return 0;
    if (message == WM_ERASEBKGND) return 1;
    if (message == WM_PAINT) { PAINTSTRUCT paint{}; BeginPaint(window, &paint); EndPaint(window, &paint); return 0; }
    if (message == WM_MOUSEACTIVATE) return MA_NOACTIVATE;
    if (message == WM_NCHITTEST) return HTTRANSPARENT;
    if (message == WM_GETOBJECT && static_cast<LONG>(lparam) == UiaRootObjectId) {
        try { auto provider = make<DecorationProvider>(window); return UiaReturnRawElementProvider(window, wparam, lparam, provider.get()); }
        catch (...) { return 0; }
    }
    if (message == RemovedMessage && self) {
        try { self->Solid(); } catch (...) {}
        PostMessageW(self->content, self->notification, reinterpret_cast<WPARAM>(window), 0); return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}
}

extern "C" __declspec(dllexport) int __cdecl pacer_surface_abi_version() noexcept { return 1; }
extern "C" __declspec(dllexport) HRESULT __cdecl pacer_surface_create(HWND content, UINT notification, void** result) noexcept {
    if (!result || notification < WM_APP || notification > 0xBFFF) return E_INVALIDARG;
    *result = nullptr;
    try {
        auto surface = std::make_unique<Surface>(content, notification); surface->Initialize();
        if (surface->removed) throw hresult_error(DXGI_ERROR_DEVICE_REMOVED);
        *result = surface.release(); return S_OK;
    } catch (...) { return to_hresult(); }
}
extern "C" __declspec(dllexport) HWND __cdecl pacer_surface_window(void* value) noexcept { return value ? static_cast<Surface*>(value)->window : nullptr; }
extern "C" __declspec(dllexport) HRESULT __cdecl pacer_surface_update(void* value, int x, int y, int width, int height, double const* points, int count, double scale, int show) noexcept {
    if (!value) return E_INVALIDARG;
    try { static_cast<Surface*>(value)->Update(x, y, width, height, points, count, static_cast<float>(scale), show != 0); return S_OK; }
    catch (...) { return to_hresult(); }
}
extern "C" __declspec(dllexport) void __cdecl pacer_surface_hide(void* value) noexcept { if (value) ShowWindow(static_cast<Surface*>(value)->window, SW_HIDE); }
extern "C" __declspec(dllexport) HRESULT __cdecl pacer_surface_black(void* value) noexcept {
    if (!value) return E_INVALIDARG;
    try { static_cast<Surface*>(value)->Solid(); return S_OK; } catch (...) { return to_hresult(); }
}
extern "C" __declspec(dllexport) void __cdecl pacer_surface_destroy(void* value) noexcept { delete static_cast<Surface*>(value); }
extern "C" __declspec(dllexport) void __cdecl pacer_surface_test_loss(void* value) noexcept { if (value) SetEvent(static_cast<Surface*>(value)->removalEvent); }
