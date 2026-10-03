"""Static mapping from short language codes to voice-guidance locale tags."""

VOICE_LOCALES: dict[str, str] = {
    "en": "en-US",
    "si": "si-LK",
    "ta": "ta-IN",
    "hi": "hi-IN",
    "fr": "fr-FR",
    "es": "es-ES",
}

DEFAULT_VOICE_LOCALE = "en-US"


def get_voice_locale(language: str) -> str:
    return VOICE_LOCALES.get(language, DEFAULT_VOICE_LOCALE)
