Fixed high disk reads and energy use on Macs where Codex can run Dot tasks. Pacer 4.4.0 checked all of Codex every two minutes, reading about 1.6 GB each time; it now checks only the part it starts. On Mac and Windows, Pacer also keeps one connection for Dot tasks instead of reconnecting every two minutes. Dot tasks still appear as quickly as before. We recommend that Mac users update.

See the [user guide](https://github.com/RyanZhangNTU/codex-pacer/blob/main/docs/guide.md) and the [full changelog](https://github.com/RyanZhangNTU/codex-pacer/blob/main/CHANGELOG.md).
