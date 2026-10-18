"""The episode selection and wording bank shared with the native host."""

import hashlib
from pathlib import Path
from typing import Literal, Self

from pydantic import BaseModel, ConfigDict, Field, model_validator

Wording = Literal[
    "canonical",
    "plain",
    "numbered",
    "questions",
    "reordered",
    "heldout-briefing",
    "heldout-reference",
]
Variant = Wording | Literal["mixed"]
TRAIN: tuple[Wording, ...] = (
    "canonical",
    "plain",
    "numbered",
    "questions",
    "reordered",
)


class PromptBank(BaseModel):
    version: Literal["hive-rules-v1"]
    introductions: dict[Wording, str]


BANK = PromptBank.model_validate_json(
    Path(__file__).with_name("prompt_bank.json").read_text()
)
CANONICAL = Path(__file__).with_name("system_prompt.txt").read_text()
assert CANONICAL.startswith(BANK.introductions["canonical"])


class PromptSelection(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, frozen=True)

    bank: Literal["hive-rules-v1"] = "hive-rules-v1"
    variant: Wording = "canonical"
    selection: Variant = "canonical"
    seed: int = Field(default=0, ge=0)

    @model_validator(mode="after")
    def validate_selection(self) -> Self:
        expected = (
            TRAIN[self.seed % len(TRAIN)]
            if self.selection == "mixed"
            else self.selection
        )
        if self.variant != expected:
            raise ValueError("resolved wording differs from episode selection")
        return self

    def system_prompt(self) -> str:
        prefix = BANK.introductions["canonical"]
        return BANK.introductions[self.variant] + CANONICAL[len(prefix) :]

    def metadata(self, system: str, user: str) -> dict:
        return {
            **self.model_dump(),
            "system_sha256": hashlib.sha256(system.encode()).hexdigest(),
            "user_sha256": hashlib.sha256(user.encode()).hexdigest(),
        }
