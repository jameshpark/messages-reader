"""Filesystem locations shared by the service and the client.

Resolved from the password database rather than $HOME so the client works
from `env -i` and the service works under launchd.
"""

import os
import pwd
from pathlib import Path


def home_dir() -> Path:
    return Path(pwd.getpwuid(os.getuid()).pw_dir)


def socket_dir() -> Path:
    return home_dir() / ".local/state/messages-reader"


def socket_path() -> Path:
    return socket_dir() / "messages-reader.sock"


def chat_db_path() -> Path:
    return home_dir() / "Library/Messages/chat.db"


def addressbook_db_paths() -> list[Path]:
    root = home_dir() / "Library/Application Support/AddressBook"
    paths = sorted(root.glob("Sources/*/AddressBook-v22.abcddb"))
    top_level = root / "AddressBook-v22.abcddb"
    if top_level.exists():
        paths.append(top_level)
    return paths
