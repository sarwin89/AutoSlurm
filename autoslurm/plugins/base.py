from __future__ import annotations

from abc import ABC, abstractmethod
from pathlib import Path

from autoslurm.config import AutoSlurmConfig
from autoslurm.results import CheckResult


class WorkflowProfile(ABC):
    code: str

    @abstractmethod
    def validate_inputs(self, workdir: Path, config: AutoSlurmConfig) -> list[CheckResult]:
        raise NotImplementedError

    @abstractmethod
    def detect_success(self, iteration_dir: Path, config: AutoSlurmConfig) -> bool:
        raise NotImplementedError

    @abstractmethod
    def detect_failures(self, iteration_dir: Path) -> list[CheckResult]:
        raise NotImplementedError
