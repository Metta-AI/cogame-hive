"""Retain proposed replies and host receipts in the private player artifact."""

from __future__ import annotations

import io
import json
import os
import urllib.request
import zipfile
from pathlib import Path
from urllib.parse import unquote, urlsplit

from pydantic import BaseModel

from prompts import PromptSelection


class Choice(BaseModel):
    action: dict
    source: str
    system: str
    user: str
    completion: str
    request_body: str = ""
    response_body: str = ""
    response_status: int = 0
    model: str = ""


class Capture:
    def __init__(self, slot: int, backend: str) -> None:
        self.slot = slot
        self.backend = backend
        self.revision = os.environ["HIVE_SOURCE_REVISION"]
        self.upload_url = os.environ["COWORLD_PLAYER_ARTIFACT_UPLOAD_URL"]
        self.rows: list[dict] = []

    def record(
        self,
        choice: Choice,
        receipt: dict,
        transmissions: int,
        selection: PromptSelection,
    ) -> None:
        self.rows.append(
            {
                "decision_id": len(self.rows),
                "tick": receipt["turn"],
                "source": choice.source,
                "prompt_template": selection.metadata(choice.system, choice.user),
                "executed_action": receipt["action"],
                "accepted": receipt["accepted"],
                "receipt": receipt,
                "transmissions": transmissions,
                "generation": {
                    key: getattr(choice, key)
                    for key in (
                        "request_body",
                        "response_body",
                        "response_status",
                        "model",
                    )
                },
                "prompt": [
                    {"role": "system", "content": choice.system},
                    {"role": "user", "content": choice.user},
                ],
                "completion": [{"role": "assistant", "content": choice.completion}],
            }
        )

    def upload(self, scores: list[float], reason: str) -> None:
        archive = io.BytesIO()
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as output:
            output.writestr(
                "trajectory.json",
                json.dumps(
                    {
                        "schema_version": 2,
                        "game": "hive",
                        "slot": self.slot,
                        "backend": self.backend,
                        "source_revision": self.revision,
                        "complete": True,
                        "reason": reason,
                        "scores": scores,
                        "decisions": self.rows,
                    }
                ),
            )
        data = archive.getvalue()
        url = urlsplit(self.upload_url)
        if url.scheme == "file":
            target = Path(unquote(url.path))
            pending = target.with_name(target.name + ".tmp")
            with os.fdopen(
                os.open(pending, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb"
            ) as output:
                output.write(data)
            os.replace(pending, target)
        else:
            request = urllib.request.Request(
                self.upload_url,
                data=data,
                method="PUT",
                headers={"Content-Type": "application/zip"},
            )
            with urllib.request.urlopen(request, timeout=10) as response:
                response.read()
