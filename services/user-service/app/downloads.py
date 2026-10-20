"""How a stored file is handed to a browser (item 9).

A verification document used to be returned as bare bytes with a media type
and nothing else. A PDF then arrived with no name, so the app could not tell
the viewer what it was opening and a browser had nothing sensible to call the
file; and without `nosniff` a browser is free to second-guess the media type,
which is exactly what you do not want for a file a stranger uploaded.

Pure string handling, so the awkward names -- Sinhala, quotes, no extension
at all -- can be tested without a database or a request (see
tests/test_downloads.py).
"""

from urllib.parse import quote

# What a stored media type should be called on disk.
_EXTENSIONS = {
    "application/pdf": ".pdf",
    "image/jpeg": ".jpg",
    "image/png": ".png",
}

FALLBACK_NAME = "document"


def extension_for(content_type: str | None) -> str:
    """The file extension for a stored content type, or "" if unknown."""
    if not content_type:
        return ""
    return _EXTENSIONS.get(content_type.split(";")[0].strip().lower(), "")


def _stem(file_name: str | None) -> str:
    """The name without any directory part or extension."""
    if not file_name:
        return ""
    name = file_name.replace("\\", "/").rsplit("/", 1)[-1].strip()
    if not name or name in (".", ".."):
        return ""
    head, dot, _tail = name.rpartition(".")
    # Only treat a trailing ".x" as an extension when something precedes it,
    # so a file called ".hidden" keeps its whole name.
    return head if dot and head else name


def download_name(file_name: str | None, content_type: str | None) -> str:
    """The name to offer, always carrying the right extension.

    The stored content type wins over whatever the upload was called: a file
    named "scan.jpeg" that was stored as a PDF is offered as "scan.pdf", so
    opening it cannot fail on the extension alone.
    """
    stem = _stem(file_name) or FALLBACK_NAME
    extension = extension_for(content_type)
    if not extension:
        # Nothing known about the type: keep the original name as it is.
        return (file_name or FALLBACK_NAME).replace("\\", "/").rsplit("/", 1)[-1] or FALLBACK_NAME
    return f"{stem}{extension}"


def _ascii_fallback(name: str, extension: str) -> str:
    """A plain-ASCII version of the name for the quoted `filename=` part.

    Characters a browser cannot read here are dropped rather than
    transliterated; `filename*` below carries the real name. Quotes and
    backslashes are removed instead of escaped, because older clients do not
    all handle the escapes and a mangled quote breaks the whole header.

    The extension is kept separate: a name written entirely in Sinhala has
    nothing left after this, and ".pdf" on its own is not a filename.
    """
    stem = name[: -len(extension)] if extension and name.endswith(extension) else name
    cleaned = "".join(
        character
        for character in stem
        if 32 <= ord(character) < 127 and character not in '"\\'
    ).strip()
    return f"{cleaned or FALLBACK_NAME}{extension}"


def content_disposition(
    file_name: str | None, content_type: str | None, *, inline: bool = True
) -> str:
    """An RFC 6266 Content-Disposition value.

    `inline` so a PDF opens in the viewer rather than going straight to the
    downloads folder. Both forms are sent: `filename=` for clients that read
    only ASCII, and `filename*=UTF-8''...` for a name in Sinhala or Tamil.
    """
    name = download_name(file_name, content_type)
    disposition = "inline" if inline else "attachment"
    ascii_name = _ascii_fallback(name, extension_for(content_type))
    header = f'{disposition}; filename="{ascii_name}"'
    if name != ascii_name:
        header += f"; filename*=UTF-8''{quote(name, safe='')}"
    return header
