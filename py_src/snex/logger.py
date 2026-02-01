from __future__ import annotations

import logging
from typing import TYPE_CHECKING

from . import interface
from .compat import override
from .models import Atom

if TYPE_CHECKING:
    from collections.abc import Iterable, Mapping


class LoggingHandler(logging.Handler):
    """
    A logging handler that logs messages to the Elixir logger.

    The Elixir log level will be set according to the numeric log level in Python.
    The standard log levels in Python (`DEBUG`, `INFO`, `WARNING`, `ERROR`, `CRITICAL`)
    translate directly; custom log levels are translated to the next higher log level.

    Log levels between `INFO` and `WARNING` are translated to `:notice`.
    Log levels higher than `CRITICAL` are translated to `:alert`.
    Log levels 10 higher than `CRITICAL` that are translated to `:emergency`.

    Adds the following metadata to the log:
    - `file` - The file the log was emitted from (full path)
    - `line` - The line the log was emitted from
    - `time` - The time the log was emitted, in microseconds since the epoch. \
        This meta will get picked up by Elixir logger and set as the log timestamp.
    - `python_logger_name` - The name of the logger
    - `python_log_level` - The original log level in Python
    - `python_module` - The module the log was emitted from
    - `python_function` - The function the log was emitted from
    - `python_process_id` - The OS PID of the process (if available)
    - `python_thread_id` - The OS TID of the thread (if available)
    - `python_thread_name` - The name of the thread (if available)
    - `python_task_name` - The name of the task (if available)
    - `python_exception` - The name of the exception type (if available)
    """

    default_metadata: dict[Atom, object]
    extra_metadata_keys: set[str]

    def __init__(
        self,
        level: int | str = logging.NOTSET,
        *,
        default_metadata: Mapping[str, object] | None = None,
        extra_metadata_keys: Iterable[str] | None = None,
    ) -> None:
        """
        Initialize the logging handler.

        Args:
            level: The log level to use
            default_metadata: The default metadata to send to the Elixir logger.
            extra_metadata_keys: Extra keys to read from the log record and send \
                to the Elixir logger as metadata.

        """
        self.default_metadata = (
            {Atom(k): v for k, v in default_metadata.items()}
            if default_metadata
            else {}
        )
        self.extra_metadata_keys = (
            set(extra_metadata_keys) if extra_metadata_keys else set()
        )

        super().__init__(level)

    @override
    def emit(self, record: logging.LogRecord) -> None:
        attrs = record.__dict__

        level = LoggingHandler._log_level_to_atom(attrs["levelno"])
        time = LoggingHandler._seconds_float_to_microseconds(attrs["created"])

        # start with the default given in __init__
        metadata = self.default_metadata.copy()

        # if not overridden by the record, set `application` and `domain`
        metadata.setdefault(Atom("application"), Atom("snex"))
        metadata.setdefault(Atom("domain"), [Atom("snex"), Atom("python")])

        # update with the record's attributes - these always take precedence
        metadata.update(
            {
                Atom("file"): attrs["pathname"],
                Atom("line"): attrs["lineno"],
                Atom("time"): time,
                Atom("python_logger_name"): attrs["name"],
                Atom("python_log_level"): attrs["levelname"],
                Atom("python_module"): attrs["module"],
                Atom("python_function"): attrs["funcName"],
            },
        )

        # some attributes might not be present in __dict__
        if process := attrs.get("process"):
            metadata[Atom("python_process_id")] = process
        if thread := attrs.get("thread"):
            metadata[Atom("python_thread_id")] = thread
        if thread_name := attrs.get("threadName"):
            metadata[Atom("python_thread_name")] = thread_name
        if task_name := attrs.get("taskName"):
            metadata[Atom("python_task_name")] = task_name
        if exc_info := attrs.get("exc_info"):
            metadata[Atom("python_exception")] = exc_info[0].__name__

        # explicitly allowed extra attributes always take precedence
        for key in self.extra_metadata_keys:
            if key in attrs:
                metadata[Atom(key)] = attrs[key]

        interface.cast(
            Atom("Elixir.Logger"),
            Atom("bare_log"),
            [level, self.format(record), metadata],
        )

    @staticmethod
    def _log_level_to_atom(level: int) -> Atom:
        atom: Atom
        if level <= logging.DEBUG:
            atom = Atom("debug")
        elif level <= logging.INFO:
            atom = Atom("info")
        elif level < logging.WARNING:
            atom = Atom("notice")
        elif level == logging.WARNING:
            atom = Atom("warning")
        elif level <= logging.ERROR:
            atom = Atom("error")
        elif level <= logging.CRITICAL:
            atom = Atom("critical")
        elif level <= logging.CRITICAL + 10:
            atom = Atom("alert")
        else:
            atom = Atom("emergency")

        return atom

    @staticmethod
    def _seconds_float_to_microseconds(seconds: float) -> int:
        timesplit = str(seconds).split(".", maxsplit=1)
        second_part = timesplit[0]
        microsecond_part = (timesplit[1] or "").ljust(6, "0")[:6]
        return int(second_part + microsecond_part)
