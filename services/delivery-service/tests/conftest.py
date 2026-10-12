import os

# Settings requires JWT_SECRET (no default); give tests a throwaway one.
os.environ.setdefault("JWT_SECRET", "test-only-signing-key-" + "x" * 16)
