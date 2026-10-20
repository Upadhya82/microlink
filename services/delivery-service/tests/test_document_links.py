"""The driver profile's document fields: an upload in user-service, or an
outside link -- and nothing else."""

import pytest
from pydantic import ValidationError

from app.schemas import AgentProfileUpsertRequest

DOC_ID = "3f2b8c1e-9d4a-4e6b-8f0c-1a2b3c4d5e6f"


def _profile(**docs):
    return AgentProfileUpsertRequest(vehicle_type="bike", **docs)


def test_uploaded_document_path_is_accepted():
    profile = _profile(
        id_document_url=f"/users/documents/{DOC_ID}/file",
        license_photo_url=f"/users/documents/{DOC_ID}/file",
        police_report_url=f"/users/documents/{DOC_ID}/file",
    )
    assert profile.id_document_url == f"/users/documents/{DOC_ID}/file"


def test_outside_link_is_still_accepted():
    profile = _profile(id_document_url="https://example.com/id.pdf")
    assert profile.id_document_url == "https://example.com/id.pdf"


def test_blank_document_is_treated_as_missing():
    assert _profile(id_document_url="   ").id_document_url is None


@pytest.mark.parametrize(
    "value",
    [
        "/users/documents/not-a-uuid/file",
        f"/users/documents/{DOC_ID}",
        f"/users/{DOC_ID}/documents",
        f"/users/documents/{DOC_ID}/file/../../admin",
        "ftp://example.com/id.pdf",
        "id.pdf",
    ],
)
def test_anything_else_is_rejected(value):
    with pytest.raises(ValidationError):
        _profile(id_document_url=value)
