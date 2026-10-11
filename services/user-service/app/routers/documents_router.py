"""Verification documents for shop owners and delivery agents.

REQ-AGENT-1 requires an ID, driving licence and police clearance before an
agent is approved; REQ-ADMIN-1/2 require the admin to see those files when
deciding. This router owns both halves: the applicant uploads, the admin
reads.

Route ordering matters here. `/users/documents/{id}/file` must be registered
before `/users/{user_id}`, or FastAPI matches the literal word "documents"
as a user id -- which is why this router is included ahead of users_router
in app/main.py.
"""

import uuid

from fastapi import APIRouter, Depends, File, Form, HTTPException, Response, UploadFile, status
from sqlalchemy.orm import Session

from app.auth import get_current_user, require_admin
from app.database import get_db
from app.images import ImageRejected, process_document
from app.models import User, UserDocument, UserRole
from app.schemas import DOCUMENT_TYPES, UserDocumentResponse

router = APIRouter(prefix="/users", tags=["documents"])

# One of each type is enough; a second upload of the same type replaces it
# rather than piling up near-identical scans for the admin to wade through.
MAX_DOCUMENTS_PER_USER = 8


def _valid_uuid(value: str) -> bool:
    try:
        uuid.UUID(value)
        return True
    except ValueError:
        return False


@router.post(
    "/me/documents",
    response_model=UserDocumentResponse,
    status_code=status.HTTP_201_CREATED,
)
async def upload_my_document(
    doc_type: str = Form(...),
    note: str | None = Form(default=None),
    file: UploadFile = File(...),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    if doc_type not in DOCUMENT_TYPES:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Unknown document type. Expected one of: {', '.join(DOCUMENT_TYPES)}.",
        )

    raw = await file.read()
    try:
        processed, content_type = process_document(raw, file.content_type)
    except ImageRejected as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc))

    existing = (
        db.query(UserDocument)
        .filter(UserDocument.user_id == current_user.id, UserDocument.doc_type == doc_type)
        .all()
    )
    for old in existing:
        db.delete(old)

    total = db.query(UserDocument).filter(UserDocument.user_id == current_user.id).count()
    if total - len(existing) >= MAX_DOCUMENTS_PER_USER:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"You can upload at most {MAX_DOCUMENTS_PER_USER} documents.",
        )

    document = UserDocument(
        user_id=current_user.id,
        doc_type=doc_type,
        file_name=(file.filename or doc_type)[:255],
        content_type=content_type,
        data=processed,
        size_bytes=len(processed),
        note=note,
    )
    db.add(document)
    db.commit()
    db.refresh(document)
    return document


@router.get("/me/documents", response_model=list[UserDocumentResponse])
async def list_my_documents(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    return (
        db.query(UserDocument)
        .filter(UserDocument.user_id == current_user.id)
        .order_by(UserDocument.created_at)
        .all()
    )


@router.delete("/me/documents/{document_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_my_document(
    document_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    # Once approved the documents are the evidence the decision was based on,
    # so they stop being the applicant's to delete.
    if current_user.is_verified:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Your account is already verified, so its documents cannot be removed.",
        )
    if not _valid_uuid(document_id):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Document not found")
    document = db.get(UserDocument, document_id)
    if document is None or document.user_id != current_user.id:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Document not found")
    db.delete(document)
    db.commit()


# Declared before /{user_id}/documents so "documents" is never read as an id.
@router.get("/documents/{document_id}/file")
async def get_document_file(
    document_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Serve a document's bytes to its owner or to an admin.

    Unlike shop photos this is not public -- these are identity documents.
    """
    if not _valid_uuid(document_id):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Document not found")
    document = db.get(UserDocument, document_id)
    if document is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Document not found")
    if current_user.role != UserRole.admin and document.user_id != current_user.id:
        # Reported as missing rather than forbidden so ids cannot be probed.
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Document not found")
    return Response(
        content=document.data,
        media_type=document.content_type,
        headers={"Cache-Control": "private, max-age=600"},
    )


@router.get("/{user_id}/documents", response_model=list[UserDocumentResponse])
async def list_user_documents(
    user_id: str,
    _admin: User = Depends(require_admin),
    db: Session = Depends(get_db),
):
    """REQ-ADMIN-1/2: what the admin reviews before approving an account."""
    if not _valid_uuid(user_id):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")
    return (
        db.query(UserDocument)
        .filter(UserDocument.user_id == user_id)
        .order_by(UserDocument.created_at)
        .all()
    )
