"""
IBus STT - Moonshine model managers

Manages discovery, downloading, and lifecycle of Moonshine ASR models.

Key differences from Whisper models:
- Moonshine models are *directories* containing multiple files
- Non-streaming models: encoder_model.ort, decoder_model_merged.ort, tokenizer.bin
- Streaming models: adapter.ort, cross_kv.ort, decoder_kv.ort, encoder.ort,
  frontend.ort, streaming_config.json, tokenizer.bin
- Models are language-specific (e.g., base-en, base-ja)
- Downloads use the moonshine_voice Python API directly
- Model architectures are identified by integer IDs from ModelArch enum
"""

import os
import json
import logging
import threading
import uuid
from pathlib import Path
from enum import Enum

from gi.repository import GObject, Gio, GLib

LOG_MSG = logging.getLogger()

# Try importing Moonshine ModelArch for correct arch values
try:
    from moonshine_voice.moonshine_api import ModelArch
    _TINY = int(ModelArch.TINY)
    _BASE = int(ModelArch.BASE)
    _TINY_STREAMING = int(ModelArch.TINY_STREAMING)
    _SMALL_STREAMING = int(ModelArch.SMALL_STREAMING)
    _MEDIUM_STREAMING = int(ModelArch.MEDIUM_STREAMING)
except ImportError:
    _TINY = 0
    _BASE = 1
    _TINY_STREAMING = 2
    _SMALL_STREAMING = 3
    _MEDIUM_STREAMING = 4

# Required files for NON-streaming models
NON_STREAMING_MODEL_FILES = [
    "encoder_model.ort",
    "decoder_model_merged.ort",
    "tokenizer.bin",
]

# Required files for STREAMING models
STREAMING_MODEL_FILES = [
    "adapter.ort",
    "cross_kv.ort",
    "decoder_kv.ort",
    "encoder.ort",
    "frontend.ort",
    "streaming_config.json",
    "tokenizer.bin",
]

# Standard directories to scan for Moonshine models
_home_cache = Path.home() / ".cache" / "moonshine_voice"
MODEL_DIRS = [
    os.getenv("MOONSHINE_VOICE_CACHE"),
    str(_home_cache),
    "/usr/share/moonshine",
    "/usr/local/share/moonshine",
]

# Language code to full name mapping
LANGUAGE_MAP = {
    "en": "english",
    "ar": "arabic",
    "ja": "japanese",
    "ko": "korean",
    "zh": "mandarin",
    "es": "spanish",
    "uk": "ukrainian",
    "vi": "vietnamese",
}

# Known Moonshine models catalog
# name -> (language_code, size_str, arch)
MOONSHINE_MODELS = {
    "tiny-en":              ("en", "26 MB",  _TINY),
    "tiny-streaming-en":    ("en", "34 MB",  _TINY_STREAMING),
    "base-en":              ("en", "58 MB",  _BASE),
    "small-streaming-en":   ("en", "123 MB", _SMALL_STREAMING),
    "medium-streaming-en":  ("en", "245 MB", _MEDIUM_STREAMING),
    "base-ar":              ("ar", "58 MB",  _BASE),
    "base-ja":              ("ja", "58 MB",  _BASE),
    "tiny-ja":              ("ja", "26 MB",  _TINY),
    "tiny-ko":              ("ko", "26 MB",  _TINY),
    "base-zh":              ("zh", "58 MB",  _BASE),
    "base-es":              ("es", "58 MB",  _BASE),
    "base-uk":              ("uk", "58 MB",  _BASE),
    "base-vi":              ("vi", "58 MB",  _BASE),
}

DOWNLOADED_MODEL_SUFFIX = ".downloading_tmp"


def _is_valid_moonshine_model_dir(dir_path):
    """Check if a directory contains valid Moonshine model files (streaming or non-streaming)."""
    p = Path(dir_path)
    if not p.is_dir():
        return False
    has_non_streaming = all((p / f).is_file() for f in NON_STREAMING_MODEL_FILES)
    has_streaming = all((p / f).is_file() for f in STREAMING_MODEL_FILES)
    return has_non_streaming or has_streaming


def _detect_model_info(model_dir_path):
    """Try to detect model name, language, and arch from directory path/name."""
    dir_name = Path(model_dir_path).name
    all_parts = Path(model_dir_path).parts

    # Try to match against known models by checking all path parts
    for part in all_parts:
        for model_name, (lang, size, arch) in MOONSHINE_MODELS.items():
            if part == model_name:
                return model_name, lang, arch

    # Try direct directory name match
    for model_name, (lang, size, arch) in MOONSHINE_MODELS.items():
        if dir_name == model_name:
            return model_name, lang, arch

    # Try to infer language from directory name pattern like "base-en"
    lang_code = None
    if "-" in dir_name:
        suffix = dir_name.split("-")[-1]
        if suffix in LANGUAGE_MAP:
            lang_code = suffix

    return dir_name, lang_code, None


class STTDownloadState(float, Enum):
    STOPPED = -1.0
    UNKNOWN_PROGRESS = -0.5
    UNPACKING = -0.6
    ONGOING = 0.0


class STTMoonshineModelDescription(GObject.Object):
    __gtype_name__ = "STTMoonshineModelDescription"

    def __init__(self, init_model=None):
        super().__init__()
        self.name = init_model.name if init_model is not None else ""
        self.custom = init_model.custom if init_model is not None else False
        self.is_obsolete = False
        self.paths = init_model.paths if init_model is not None else []
        self.size = init_model.size if init_model is not None else ""
        self.type = init_model.type if init_model is not None else ""
        self.locale = init_model.locale if init_model is not None else ""
        self.url = init_model.url if init_model is not None else ""
        self.arch = init_model.arch if init_model is not None else None

        self._operation = None
        self.download_progress = STTDownloadState.STOPPED

    def _download_finished(self):
        if self._operation is not None and self._operation.is_cancelled():
            self._operation = None

    def _download_model_thread(self, model_name, language, status):
        """Download a Moonshine model using the moonshine_voice API directly."""
        try:
            from moonshine_voice.download import find_model_info, download_model_from_info

            self.download_progress = STTDownloadState.UNKNOWN_PROGRESS

            if status.is_cancelled():
                self.download_progress = STTDownloadState.STOPPED
                return

            LOG_MSG.info(
                "Downloading Moonshine model: name=%s, language=%s",
                model_name, language,
            )

            # Find the specific model arch from our catalog
            target_arch = None
            for cat_name, (cat_lang, cat_size, cat_arch) in MOONSHINE_MODELS.items():
                if cat_name == model_name:
                    target_arch = cat_arch
                    break

            # Get model info for the specific arch
            model_info = find_model_info(language, target_arch)

            if status.is_cancelled():
                self.download_progress = STTDownloadState.STOPPED
                return

            self.download_progress = 0.3
            model_path, model_arch = download_model_from_info(model_info)

            if status.is_cancelled():
                self.download_progress = STTDownloadState.STOPPED
                return

            if model_path and Path(model_path).is_dir():
                self.arch = int(model_arch)
                if model_path not in self.paths:
                    self.paths.append(model_path)
                LOG_MSG.info(
                    "Model downloaded: path=%s, arch=%s", model_path, model_arch
                )
            else:
                LOG_MSG.error("Download completed but model path invalid: %s", model_path)

        except ImportError:
            LOG_MSG.error(
                "moonshine_voice not installed. Install with: pip install moonshine-voice"
            )
        except Exception as e:
            LOG_MSG.error("Download error: %s", e, exc_info=True)

        self.download_progress = STTDownloadState.STOPPED
        GLib.idle_add(self._download_finished)

    def stop_downloading(self):
        if self._operation is not None:
            self._operation.cancel()

    def start_downloading(self):
        if self._operation is not None:
            return

        # Resolve language from locale
        lang_code = self.locale if self.locale else "en"

        LOG_MSG.debug("start downloading Moonshine model (%s, lang=%s)", self.name, lang_code)

        self.download_progress = STTDownloadState.ONGOING
        self._operation = Gio.Cancellable()

        download_thread = threading.Thread(
            target=self._download_model_thread,
            args=(self.name, lang_code, self._operation),
            daemon=True,
        )
        download_thread.start()

    def get_best_path_for_model(self):
        if self.paths in [None, []]:
            return None
        return self.paths[0]

    def delete_paths(self):
        if self.custom is True:
            return

        for path in self.paths:
            model_dir = Path(path)
            # Only delete from the user cache directory
            if str(model_dir).startswith(str(_home_cache)):
                try:
                    if model_dir.is_dir():
                        import shutil
                        shutil.rmtree(model_dir)
                    elif model_dir.is_file():
                        model_dir.unlink()
                except Exception as e:
                    LOG_MSG.error("Failed to delete %s: %s", path, e)

        self._operation = None
        self.download_progress = STTDownloadState.STOPPED
        self.paths = []


class STTMoonshineLocalModelManager(GObject.Object):
    __gtype_name__ = "STTMoonshineLocalModelManager"

    __gsignals__ = {
        "added": (GObject.SIGNAL_RUN_FIRST, None, (str, str)),
        "removed": (GObject.SIGNAL_RUN_FIRST, None, (str, str)),
    }

    def __init__(self):
        super().__init__()
        self._monitors = []
        self._models_dict = {}       # model_name -> model_desc
        self._locales_dict = {}      # locale -> [model_desc, ...]
        self._model_paths_dict = {}  # path_str -> model_desc
        self._custom_paths = {}
        self._get_available_local_models()

    def _add_model_description_to_locale(self, model_desc):
        if model_desc.locale is None:
            return

        models_list = self._locales_dict.get(model_desc.locale, None)
        if models_list is None:
            self._locales_dict[model_desc.locale] = [model_desc]
        else:
            if model_desc not in models_list:
                models_list.append(model_desc)

    def _new_model_available(self, model_path):
        """Register a newly discovered Moonshine model directory."""
        model_path = Path(model_path)

        if str(model_path).endswith(DOWNLOADED_MODEL_SUFFIX):
            LOG_MSG.debug("model path is a temporary file (%s)", model_path)
            return None

        if not _is_valid_moonshine_model_dir(model_path):
            LOG_MSG.debug("not a valid Moonshine model directory (%s)", model_path)
            return None

        if not os.access(model_path, os.R_OK):
            LOG_MSG.debug("access rights are wrong (%s)", model_path)
            return None

        path_str = str(model_path)
        if self.path_available(path_str):
            LOG_MSG.debug("model directory already in list (%s)", model_path)
            return None

        model_name, lang_code, arch = _detect_model_info(model_path)

        # Check if this is a custom path (not in standard dirs)
        is_in_standard_dir = False
        for d in MODEL_DIRS:
            if d and path_str.startswith(str(d)):
                is_in_standard_dir = True
                break

        if not is_in_standard_dir:
            # Custom model
            model_desc = STTMoonshineModelDescription()
            model_desc.paths = [path_str]
            model_desc.name = model_name
            model_desc.custom = True
            model_desc.locale = lang_code
            model_desc.arch = arch

            self._models_dict[path_str] = model_desc
            self._model_paths_dict[path_str] = model_desc

            LOG_MSG.debug("custom Moonshine model found (%s)", model_path)
            return model_desc

        # Standard model
        model_desc = self._models_dict.get(model_name, None)
        if model_desc is None:
            model_desc = STTMoonshineModelDescription()
            model_desc.paths = [path_str]
            model_desc.locale = lang_code
            model_desc.name = model_name
            model_desc.arch = arch

            # Look up size from catalog
            if model_name in MOONSHINE_MODELS:
                _, size, catalog_arch = MOONSHINE_MODELS[model_name]
                model_desc.size = size
                if model_desc.arch is None:
                    model_desc.arch = catalog_arch

            self._add_model_description_to_locale(model_desc)
            self._models_dict[model_name] = model_desc
            self._model_paths_dict[path_str] = model_desc

            LOG_MSG.debug("Moonshine model found (%s) - new", model_path)
            self.emit("added", model_name, path_str)
            return model_desc

        # Already known model name, add this path
        if path_str not in model_desc.paths:
            model_desc.paths.append(path_str)

        self._model_paths_dict[path_str] = model_desc

        LOG_MSG.debug("Moonshine model found (%s) - already known", model_path)
        self.emit("added", model_name, path_str)
        return model_desc

    def _remove_model_description(self, model_path_str):
        model_desc = self._model_paths_dict.pop(model_path_str, None)
        if model_desc is None:
            return

        LOG_MSG.debug("model removed (%s)", model_path_str)

        if model_path_str in model_desc.paths:
            model_desc.paths.remove(model_path_str)

        if not any(model_desc.paths):
            models_list = self._locales_dict.get(model_desc.locale, [])
            if model_desc in models_list:
                models_list.remove(model_desc)
            if not any(models_list):
                self._locales_dict.pop(model_desc.locale, None)

            key = model_desc.name if not model_desc.custom else model_path_str
            self._models_dict.pop(key, None)

        model_name = model_desc.name if not model_desc.custom else None
        self.emit("removed", model_name, model_path_str)

    def _model_dir_changed_cb(self, monitor, file, other_file, event_type):
        """Handle filesystem changes in model directories."""
        file_path = file.get_path()

        # Skip top-level directory events
        if file_path in [str(d) for d in MODEL_DIRS if d]:
            return

        LOG_MSG.info(
            "a model directory changed (%s) (event=%s)", file_path, event_type
        )

        if event_type == Gio.FileMonitorEvent.CHANGES_DONE_HINT:
            if file_path.endswith(DOWNLOADED_MODEL_SUFFIX):
                return
            path = Path(file_path)
            # Walk up to find a valid model dir
            for candidate in [path, path.parent, path.parent.parent]:
                if _is_valid_moonshine_model_dir(candidate):
                    self._new_model_available(candidate)
                    return

        elif event_type == Gio.FileMonitorEvent.DELETED:
            self._remove_model_description(file_path)

    def _scan_directory_recursive(self, directory_path, depth=0, max_depth=6):
        """Scan a directory for Moonshine model subdirectories."""
        if not directory_path.is_dir() or depth > max_depth:
            return

        # Check if this directory itself is a model
        if _is_valid_moonshine_model_dir(directory_path):
            self._new_model_available(directory_path)
            return

        # Recurse into children
        try:
            for child in directory_path.iterdir():
                if child.is_dir():
                    self._scan_directory_recursive(child, depth + 1, max_depth)
        except PermissionError:
            LOG_MSG.debug("permission denied scanning %s", directory_path)

    def _get_available_local_models(self):
        """Scan all model directories for available models."""
        for directory in MODEL_DIRS:
            LOG_MSG.debug("scanning %s for Moonshine models", directory)

            if directory is None:
                continue

            dir_path = Path(directory)

            # Set up file monitoring
            monitor = Gio.File.new_for_path(str(dir_path)).monitor_directory(
                Gio.FileMonitorFlags.NONE, None
            )
            if monitor is not None:
                monitor.connect("changed", self._model_dir_changed_cb)
                self._monitors.append(monitor)

            self._scan_directory_recursive(dir_path)

    def path_available(self, model_path):
        return model_path in self._model_paths_dict

    def get_models_for_locale(self, locale_str):
        # Try exact match first, then 2-letter code
        models = self._locales_dict.get(locale_str, []).copy()
        short_locale = locale_str[:2] if len(locale_str) > 2 else locale_str
        if short_locale != locale_str:
            models.extend(self._locales_dict.get(short_locale, []))
        return models

    def get_best_path_for_model(self, model_name):
        if model_name is None:
            return None

        model = self._models_dict.get(model_name, None)
        if model is None:
            return None

        if model.paths in [None, []]:
            return None

        return model.paths[0]

    def get_model_description(self, model_name):
        return self._models_dict.get(model_name, None)

    def get_model_description_by_path(self, model_path):
        return self._model_paths_dict.get(model_path, None)

    def get_supported_locales(self):
        return list(self._locales_dict.keys())

    def _custom_model_dir_changed_cb(self, monitor, file, other_file, event_type):
        file_path = file.get_path()
        LOG_MSG.info(
            "custom model changed (%s) (event=%s)", file_path, event_type
        )
        if event_type == Gio.FileMonitorEvent.CHANGES_DONE_HINT:
            path = Path(file_path)
            if _is_valid_moonshine_model_dir(path):
                self._new_model_available(path)
            elif _is_valid_moonshine_model_dir(path.parent):
                self._new_model_available(path.parent)

        elif event_type == Gio.FileMonitorEvent.DELETED:
            model = self._model_paths_dict.get(file_path, None)
            if model is None:
                return
            self._model_paths_dict.pop(file_path, None)
            self.emit("removed", None, file_path)

    def register_custom_model_path(self, model_path_str, locale_str):
        """Register a custom model path outside standard directories."""
        for d in MODEL_DIRS:
            if d and model_path_str.startswith(str(d)):
                LOG_MSG.debug(
                    "registered path is in standard directory (%s)", model_path_str
                )
                return

        monitor = self._custom_paths.get(model_path_str, None)
        if monitor is not None:
            monitor.refcount += 1
            LOG_MSG.debug(
                "custom path already registered (%s). refcount=%i",
                model_path_str,
                monitor.refcount,
            )
            return

        # Monitor the directory for changes
        monitor = Gio.File.new_for_path(model_path_str).monitor_directory(
            Gio.FileMonitorFlags.NONE, None
        )
        if monitor is not None:
            monitor.connect("changed", self._custom_model_dir_changed_cb)
            self._custom_paths[model_path_str] = monitor
            monitor.refcount = 1

        model_desc = self._new_model_available(Path(model_path_str))
        if model_desc:
            model_desc.locale = locale_str
            self._add_model_description_to_locale(model_desc)
            self.emit("added", None, model_path_str.rstrip("/"))

    def unregister_custom_model_path(self, model_path_str):
        monitor = self._custom_paths.get(model_path_str, None)
        if monitor is None:
            LOG_MSG.debug(
                "trying to unregister unknown custom path (%s)", model_path_str
            )
            return

        if monitor.refcount != 1:
            monitor.refcount -= 1
            return

        self._custom_paths.pop(model_path_str, None)
        self._remove_model_description(model_path_str)


_GLOBAL_LOCAL_MANAGER = None


def stt_moonshine_local_model_manager():
    global _GLOBAL_LOCAL_MANAGER
    if _GLOBAL_LOCAL_MANAGER is None:
        _GLOBAL_LOCAL_MANAGER = STTMoonshineLocalModelManager()
    return _GLOBAL_LOCAL_MANAGER


class STTMoonshineOnlineModelManager(GObject.Object):
    __gtype_name__ = "STTMoonshineOnlineModelManager"
    __gsignals__ = {
        "added": (GObject.SIGNAL_RUN_FIRST, None, (object,)),
        "changed": (GObject.SIGNAL_RUN_FIRST, None, (object,)),
        "removed": (GObject.SIGNAL_RUN_FIRST, None, (object,)),
    }

    def __init__(self):
        super().__init__()

        self._locales_dict = {}
        self._online_models = {}

        local_manager = stt_moonshine_local_model_manager()
        local_manager.connect("added", self._model_path_added_cb)
        local_manager.connect("removed", self._model_path_removed_cb)
        self._populate_with_moonshine_models()

    def _populate_with_moonshine_models(self):
        """Populate the catalog with known Moonshine models."""
        for model_name, (lang_code, size, arch) in MOONSHINE_MODELS.items():
            model_desc = STTMoonshineModelDescription()
            model_desc.name = model_name
            model_desc.size = size
            model_desc.locale = lang_code
            model_desc.arch = arch
            model_desc.url = "https://download.moonshine.ai/model/" + model_name

            # Determine model type (architecture variant)
            if "streaming" in model_name:
                parts = model_name.split("-")
                model_desc.type = "-".join(parts[:-1])
            else:
                model_desc.type = model_name.split("-")[0]

            # Check if already downloaded locally
            local_desc = stt_moonshine_local_model_manager().get_model_description(
                model_name
            )
            if local_desc is not None:
                model_desc.paths = local_desc.paths
                if local_desc.arch is not None:
                    model_desc.arch = local_desc.arch

            if model_name in self._online_models:
                existing = self._online_models[model_name]
                if not existing.paths and model_desc.paths:
                    existing.paths = model_desc.paths
                continue

            self._online_models[model_name] = model_desc
            self._add_model_description_to_locale(model_desc)

        # Also add any locally-found models not in the catalog
        for locale in stt_moonshine_local_model_manager().get_supported_locales():
            model_list = stt_moonshine_local_model_manager().get_models_for_locale(
                locale
            )
            for model_desc in model_list:
                key = model_desc.name if not model_desc.custom else model_desc.paths[0]
                if key in self._online_models:
                    continue

                LOG_MSG.debug("adding local-only model to catalog (%s)", key)
                self._online_models[key] = model_desc
                self._add_model_description_to_locale(model_desc)

    def _add_model_description_to_locale(self, model_desc):
        locale_models = self._locales_dict.get(model_desc.locale, None)
        if locale_models is None:
            self._locales_dict[model_desc.locale] = [model_desc]
        else:
            if model_desc not in locale_models:
                locale_models.append(model_desc)

    def _model_path_added_cb(self, manager, model_name, model_path):
        if model_name is not None:
            online_model_desc = self._online_models.get(model_name, None)
            local_model_desc = manager.get_model_description(model_name)
        else:
            online_model_desc = self._online_models.get(model_path, None)
            local_model_desc = manager.get_model_description_by_path(model_path)

        if local_model_desc is None:
            return

        if online_model_desc is not None:
            if online_model_desc.paths in [None, []]:
                online_model_desc.paths = local_model_desc.paths
            if local_model_desc.arch is not None:
                online_model_desc.arch = local_model_desc.arch

            self.emit("changed", online_model_desc)
            return

        key = (
            local_model_desc.name
            if not local_model_desc.custom
            else local_model_desc.paths[0]
        )
        self._online_models[key] = local_model_desc
        self._add_model_description_to_locale(local_model_desc)
        self.emit("added", local_model_desc)

    def _remove_model_description_from_locale(self, model_desc):
        locale_models = self._locales_dict.get(model_desc.locale, None)
        if locale_models and model_desc in locale_models:
            locale_models.remove(model_desc)
        if locale_models is not None and not any(locale_models):
            self._locales_dict.pop(model_desc.locale, None)

    def _model_path_removed_cb(self, manager, model_name, model_path):
        if model_name is None:
            online_model_desc = self._online_models.pop(model_path, None)
            if online_model_desc:
                self._remove_model_description_from_locale(online_model_desc)
                self.emit("removed", online_model_desc)
            return

        online_model_desc = self._online_models.get(model_name, None)
        if online_model_desc is None:
            return

        if any(online_model_desc.paths):
            self.emit("changed", online_model_desc)
            return

        # Keep catalog entries (they can be re-downloaded)
        if model_name in MOONSHINE_MODELS:
            self.emit("changed", online_model_desc)
            return

        self._online_models.pop(model_name, None)
        self._remove_model_description_from_locale(online_model_desc)
        self.emit("removed", online_model_desc)

    def get_model_description(self, model_name):
        return self._online_models.get(model_name, None)

    def get_models_for_locale(self, locale_str):
        models = self._locales_dict.get(locale_str, []).copy()
        short_locale = locale_str[:2] if len(locale_str) > 2 else locale_str
        if short_locale != locale_str:
            models.extend(self._locales_dict.get(short_locale, []))
        # Deduplicate
        seen = set()
        result = []
        for m in models:
            if m.name not in seen:
                seen.add(m.name)
                result.append(m)
        return result

    def supported_locales(self):
        return list(self._locales_dict.keys())


_GLOBAL_ONLINE_MANAGER = None


def stt_moonshine_online_model_manager():
    global _GLOBAL_ONLINE_MANAGER
    if _GLOBAL_ONLINE_MANAGER is None:
        _GLOBAL_ONLINE_MANAGER = STTMoonshineOnlineModelManager()
    return _GLOBAL_ONLINE_MANAGER














def _download_model_thread(self, model_name, language, status):
        """Download a Moonshine model using the moonshine_voice CLI."""
        import subprocess
        import re

        try:
            self.download_progress = STTDownloadState.UNKNOWN_PROGRESS

            if status.is_cancelled():
                self.download_progress = STTDownloadState.STOPPED
                return

            LOG_MSG.info(
                "Downloading Moonshine model: name=%s, language=%s",
                model_name, language,
            )

            process = subprocess.Popen(
                ["python3", "-m", "moonshine_voice.download", "--language", language],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )

            model_path = None
            model_arch = None

            for line in process.stdout:
                if status.is_cancelled():
                    process.kill()
                    self.download_progress = STTDownloadState.STOPPED
                    return

                line = line.strip()
                LOG_MSG.debug("moonshine download: %s", line)

                # Parse percentage from pip-style progress bars like "45%|███"
                pct_match = re.search(r'(\d+)%\|', line)
                if pct_match:
                    pct = int(pct_match.group(1))
                    self.download_progress = max(pct / 100.0, STTDownloadState.ONGOING)

                # Parse "Downloaded model path: /path/to/model"
                if "Downloaded model path:" in line:
                    model_path = line.split("Downloaded model path:")[-1].strip()

                # Parse "Model arch: 1"
                if "Model arch:" in line:
                    try:
                        model_arch = int(line.split("Model arch:")[-1].strip())
                    except ValueError:
                        pass

            process.wait()

            if process.returncode != 0:
                LOG_MSG.error("Moonshine download failed with return code %d", process.returncode)
                self.download_progress = STTDownloadState.STOPPED
                GLib.idle_add(self._download_finished)
                return

            if model_path:
                self.arch = model_arch
                if model_path not in self.paths:
                    self.paths.append(model_path)
                LOG_MSG.info(
                    "Model downloaded: path=%s, arch=%s", model_path, model_arch
                )
            else:
                LOG_MSG.error("Download completed but no model path found in output")

        except FileNotFoundError:
            LOG_MSG.error(
                "python3 or moonshine_voice not found. "
                "Install with: pip install moonshine-voice"
            )
        except Exception as e:
            LOG_MSG.error("Download error: %s", e)

        self.download_progress = STTDownloadState.STOPPED
        GLib.idle_add(self._download_finished)







From 0000000000000000000000000000000000000000 Mon Sep 17 00:00:00 2001
From: User <user@example.com>
Date: Thu, 02 Apr 2026 00:00:00 +0530
Subject: [PATCH] Add Moonshine ASR backend support

Integrates Moonshine Voice (moonshine-voice) as a third speech recognition
backend alongside Vosk and WhisperCpp. Moonshine models are language-specific
directories containing .ort files, offering low-latency streaming transcription
optimized for live speech.

New files:
  - engine/sttgstmoonshine.py      - GStreamer pipeline + Moonshine Transcriber
  - engine/sttmoonshinemodel.py    - Model settings manager (GSettings)
  - engine/sttmoonshinemodelmanagers.py - Local/online model discovery & download

Modified files:
  - data/org.freedesktop.ibus.engine.stt.gschema.xml.in - Add moonshine-models key
  - engine/meson.build             - Register new source files
  - engine/sttconfigdialog.py      - Add Moonshine to backend dropdown
  - engine/sttconfigdialog.ui      - Add "Moonshine" option to UI dropdown
  - engine/sttgstfactory.py        - Instantiate Moonshine engine when selected
  - engine/sttlocalerow.py         - Support Moonshine model type in locale rows
  - engine/sttmodelchooserdialog.py - Support Moonshine model chooser
---
diff --git a/data/org.freedesktop.ibus.engine.stt.gschema.xml.in b/data/org.freedesktop.ibus.engine.stt.gschema.xml.in
index fa695b9..XXXXXXX 100644
--- a/data/org.freedesktop.ibus.engine.stt.gschema.xml.in
+++ b/data/org.freedesktop.ibus.engine.stt.gschema.xml.in
@@ -44,7 +44,7 @@
     <key type="s" name="backend">
       <summary>Speech recognition backend</summary>
       <default>'vosk'</default>
-      <description>Choose the speech recognition backend: 'vosk' or 'whisper'</description>
+      <description>Choose the speech recognition backend: 'vosk', 'whisper', or 'moonshine'</description>
     </key>
     <key type="s" name="whisper-models">
       <summary>Paths to Whisper models</summary>
@@ -51,5 +51,10 @@
       <default>'None'</default>
       <description>A JSON formatted string that is used to associate locales with their Whisper models. It can be the name of a model if it is in default monitored paths or a custom path.</description>
     </key>
+    <key type="s" name="moonshine-models">
+      <summary>Paths to Moonshine models</summary>
+      <default>'None'</default>
+      <description>A JSON formatted string that is used to associate locales with their Moonshine ASR models. It can be a model name (e.g. base-en) if in a default cache path or a custom absolute path to a model directory.</description>
+    </key>
   </schema>
 </schemalist>
diff --git a/engine/meson.build b/engine/meson.build
index 7e0c4f4..XXXXXXX 100644
--- a/engine/meson.build
+++ b/engine/meson.build
@@ -5,12 +5,14 @@ stt_sources = [
     'sttengine.py',
     'sttgstvosk.py',
     'sttgstwhisper.py',
+    'sttgstmoonshine.py',
     'sttgstfactory.py',
     'sttgstbase.py',
     'sttsegmentprocess.py',
     'sttconfigdialog.py',
     'sttlocalerow.py',
     'sttvoskmodel.py',
+    'sttmoonshinemodel.py',
     'sttwhispermodel.py',
     'sttcurrentlocale.py',
     'sttutterancetree.py',
@@ -20,6 +22,7 @@ stt_sources = [
     'sttmodelchooserdialog.py',
     'sttvoskmodelmanagers.py',
     'sttwhispermodelmanagers.py',
+    'sttmoonshinemodelmanagers.py',
     'sttwordstodigits.py',
     'sttmodelrow.py'
     ]
diff --git a/engine/sttconfigdialog.ui b/engine/sttconfigdialog.ui
index dfd6df4..XXXXXXX 100644
--- a/engine/sttconfigdialog.ui
+++ b/engine/sttconfigdialog.ui
@@ -5,6 +5,7 @@
   <object class="GtkStringList" id="backend_list">
     <items>
       <item translatable="yes">Vosk</item>
       <item translatable="yes">Whisper</item>
+      <item translatable="yes">Moonshine</item>
     </items>
   </object>
diff --git a/engine/sttconfigdialog.py b/engine/sttconfigdialog.py
index 331b4f2..XXXXXXX 100644
--- a/engine/sttconfigdialog.py
+++ b/engine/sttconfigdialog.py
@@ -36,6 +36,7 @@
 from sttcurrentlocale import stt_current_locale
 from sttvoskmodelmanagers import stt_vosk_online_model_manager
 from sttwhispermodelmanagers import stt_whisper_online_model_manager
+from sttmoonshinemodelmanagers import stt_moonshine_online_model_manager
 
 from sttgstvosk import STTGstVosk
 
@@ -87,7 +88,12 @@ def __init__(self, *args, **kwargs):
         # Setup backend selection
         self._backend_changed_id = self._settings.connect("changed::backend", self._backend_changed_cb)
         backend = self._settings.get_string("backend")
-        self.backend_dropdown.set_selected(0 if backend == "vosk" else 1)
+        backend_index = {"vosk": 0, "whisper": 1, "moonshine": 2}.get(backend, 0)
+        self.backend_dropdown.set_selected(backend_index)
 
         self._locales = {}
         self._values_dict={}
@@ -98,6 +104,7 @@ def __init__(self, *args, **kwargs):
         # Make sure it is initialized before what follows
         stt_vosk_online_model_manager()
         stt_whisper_online_model_manager()
+        stt_moonshine_online_model_manager()
 
         # Load current locale
         self._current_locale = stt_current_locale()
@@ -249,7 +256,8 @@ def open_locale_file_cb(self, dialog, response):
     @Gtk.Template.Callback()
     def backend_dropdown_selected_cb(self, dropdown, param):
         selected = dropdown.get_selected()
-        backend = "vosk" if selected == 0 else "whisper"
+        backend_map = {0: "vosk", 1: "whisper", 2: "moonshine"}
+        backend = backend_map.get(selected, "vosk")
         current_backend = self._settings.get_string("backend")
 
         if backend != current_backend:
diff --git a/engine/sttgstfactory.py b/engine/sttgstfactory.py
index 6dc16f2..XXXXXXX 100644
--- a/engine/sttgstfactory.py
+++ b/engine/sttgstfactory.py
@@ -26,6 +26,7 @@
 
 from sttgstvosk import STTGstVosk
 from sttgstwhisper import STTGstWhisper
+from sttgstmoonshine import STTGstMoonshine
 
 LOG_MSG=logging.getLogger()
 
@@ -49,6 +50,9 @@ def new_engine(self):
             backend = self.__settings.get_string("backend")
             if backend == "whisper":
                 LOG_MSG.info("Using Whisper backend")
                 engine=STTGstWhisper()
+            elif backend == "moonshine":
+                LOG_MSG.info("Using Moonshine backend")
+                engine=STTGstMoonshine()
             else:
                 LOG_MSG.info("Using Vosk backend")
                 engine=STTGstVosk()
diff --git a/engine/sttlocalerow.py b/engine/sttlocalerow.py
index 405342c..XXXXXXX 100644
--- a/engine/sttlocalerow.py
+++ b/engine/sttlocalerow.py
@@ -32,8 +32,10 @@
 from sttutils import *
 
 from sttvoskmodel import STTVoskModel
 from sttwhispermodel import STTWhisperModel
+from sttmoonshinemodel import STTMoonshineModel
 from sttmodelchooserdialog import STTModelChooserDialog
 from sttvoskmodelmanagers import stt_vosk_online_model_manager
 from sttwhispermodelmanagers import stt_whisper_online_model_manager
+from sttmoonshinemodelmanagers import stt_moonshine_online_model_manager
 
 
@@ -78,7 +80,13 @@ def __init__(self, current_locale=None, locale_str=None, radio_group=None):
     def _init_model(self):
         backend = self._settings.get_string("backend")
-        self._model = STTWhisperModel(locale_str=self._locale) if backend == "whisper" else STTVoskModel(locale_str=self._locale)
+        if backend == "moonshine":
+            self._model = STTMoonshineModel(locale_str=self._locale)
+        elif backend == "whisper":
+            self._model = STTWhisperModel(locale_str=self._locale)
+        else:
+            self._model = STTVoskModel(locale_str=self._locale)
 
         self._model.connect("changed", self._model_changed)
         self.update_description()
@@ -131,8 +139,14 @@ def update_description(self):
             else:
                 self.set_subtitle(_("Custom model installed manually in a non-standard directory"))
             return
 
         backend = self._settings.get_string("backend")
-        manager = stt_whisper_online_model_manager() if backend == "whisper" else stt_vosk_online_model_manager()
+        if backend == "moonshine":
+            manager = stt_moonshine_online_model_manager()
+        elif backend == "whisper":
+            manager = stt_whisper_online_model_manager()
+        else:
+            manager = stt_vosk_online_model_manager()
+
         model = manager.get_model_description(model_name)
         if model is None:
             size=_("unknown size")
diff --git a/engine/sttmodelchooserdialog.py b/engine/sttmodelchooserdialog.py
index 46eb388..XXXXXXX 100644
--- a/engine/sttmodelchooserdialog.py
+++ b/engine/sttmodelchooserdialog.py
@@ -28,6 +28,8 @@
 from sttmodelrow import STTModelRow
 from sttvoskmodelmanagers import stt_vosk_online_model_manager
 from sttwhispermodelmanagers import stt_whisper_online_model_manager
+from sttmoonshinemodelmanagers import stt_moonshine_online_model_manager
+from sttmoonshinemodel import STTMoonshineModel
 from sttwhispermodel import STTWhisperModel
 
 LOG_MSG=logging.getLogger()
@@ -58,8 +60,14 @@ def __init__(self, model=None, **kwargs):
 
         self._model=model
 
-        self._is_whisper = isinstance(model, STTWhisperModel)
-        self._manager = stt_whisper_online_model_manager() if self._is_whisper else stt_vosk_online_model_manager()
+        self._is_moonshine = isinstance(model, STTMoonshineModel)
+        self._is_whisper = isinstance(model, STTWhisperModel)
+        if self._is_moonshine:
+            self._manager = stt_moonshine_online_model_manager()
+        elif self._is_whisper:
+            self._manager = stt_whisper_online_model_manager()
+        else:
+            self._manager = stt_vosk_online_model_manager()
 
         locale_str=model.get_locale()
         full_list=[]
 
-        # For Whisper, use deduplication to avoid showing multilingual models twice
-        if self._is_whisper:
+        # For Whisper/Moonshine, use deduplication to avoid showing models twice
+        if self._is_whisper or self._is_moonshine:
             seen_models = set()
             models_to_check = [locale_str]
             if len(locale_str) > 2:
@@ -97,8 +105,12 @@ def __init__(self, model=None, **kwargs):
         self._removed_id = self._manager.connect("removed", self._model_path_removed_cb)
 
         # Update dialog title based on backend
-        backend_name = "Whisper" if self._is_whisper else "Vosk"
+        if self._is_moonshine:
+            backend_name = "Moonshine"
+        elif self._is_whisper:
+            backend_name = "Whisper"
+        else:
+            backend_name = "Vosk"
         self.set_title(_("Manage %s Recognition Models") % backend_name)
 
     def _add_row(self, model_desc):
@@ -144,9 +156,14 @@ def _open_locale_file_cb(self, dialog, response):
     @Gtk.Template.Callback()
     def new_model_button_clicked_cb(self, button):
         root_widget=self.get_root()
-        # For Whisper, allow selecting files; for Vosk, allow selecting folders
-        if self._is_whisper:
+        # For Whisper, allow selecting files;
+        # For Moonshine and Vosk, allow selecting folders (model directories)
+        if self._is_moonshine:
+            action = Gtk.FileChooserAction.SELECT_FOLDER
+            title = _("Open Moonshine Model Folder")
+        elif self._is_whisper:
             action = Gtk.FileChooserAction.OPEN
             title = _("Open Whisper Model File")
         else:






  --------- Sttgstmoonshine  ----------------

"""
IBus STT - Moonshine ASR GStreamer integration

This module provides the GStreamer-based audio pipeline for the Moonshine
speech recognition backend. It captures audio from PulseAudio, feeds it
to a Moonshine Transcriber, and emits recognized text via GObject signals.
"""

import logging
import threading
import queue
import numpy as np

from pathlib import Path
from gi.repository import Gst, GLib
from sttutils import *
from sttgstbase import STTGstBase
from sttcurrentlocale import stt_current_locale
from sttmoonshinemodel import STTMoonshineModel

LOG_MSG = logging.getLogger()

try:
    from moonshine_voice.transcriber import Transcriber, TranscriptEventListener
    MOONSHINE_AVAILABLE = True
except ImportError:
    LOG_MSG.warning(
        "moonshine-voice not available. Install with: pip install moonshine-voice"
    )
    MOONSHINE_AVAILABLE = False


class _MoonshineListener(TranscriptEventListener):
    """Listener that bridges Moonshine transcript events to GLib main loop."""

    def __init__(self, emit_callback):
        self._emit_callback = emit_callback

    def on_line_completed(self, event):
        text = event.line.text.strip()
        if text:
            LOG_MSG.info("Moonshine transcription result: '%s'", text)
            GLib.idle_add(self._emit_callback, text)

    def on_line_text_changed(self, event):
        # For partial results support in the future
        pass

    def on_line_started(self, event):
        pass


class STTGstMoonshine(STTGstBase):
    __gtype_name__ = 'STTGstMoonshine'

    _pipeline_def = (
        "pulsesrc blocksize=3200 buffer-time=9223372036854775807 ! "
        "audio/x-raw,format=S16LE,rate=16000,channels=1 ! "
        "webrtcdsp noise-suppression-level=3 echo-cancel=false ! "
        "queue ! "
        "appsink name=MoonshineSink emit-signals=true sync=false"
    )

    _pipeline_def_alt = (
        "pulsesrc blocksize=3200 buffer-time=9223372036854775807 ! "
        "audio/x-raw,format=S16LE,rate=16000,channels=1 ! "
        "queue ! "
        "appsink name=MoonshineSink emit-signals=true sync=false"
    )

    def __init__(self, current_locale=None):
        plugin = Gst.Registry.get().find_plugin("webrtcdsp")
        if plugin is not None:
            super().__init__(pipeline_definition=STTGstMoonshine._pipeline_def)
            LOG_MSG.debug("using Webrtcdsp plugin")
        else:
            super().__init__(pipeline_definition=STTGstMoonshine._pipeline_def_alt)
            LOG_MSG.debug("not using Webrtcdsp plugin")

        if self.pipeline is None:
            LOG_MSG.error("pipeline was not created")
            return

        self._appsink = self.pipeline.get_by_name("MoonshineSink")
        if self._appsink is None:
            LOG_MSG.error("no appsink element!")
            return

        self._appsink.connect("new-sample", self._on_new_sample)

        if current_locale is None:
            self._current_locale = stt_current_locale()
        else:
            self._current_locale = current_locale

        self._locale_id = self._current_locale.connect(
            "changed", self._locale_changed
        )

        self._model_id = 0
        self._model = None
        self._transcriber = None
        self._listener = None
        self._sample_rate = 16000
        self._transcriber_started = False

        self._set_model()

    def __del__(self):
        LOG_MSG.info("Moonshine __del__")
        self._stop_transcriber()
        super().__del__()

    def destroy(self):
        self._stop_transcriber()

        self._current_locale.disconnect(self._locale_id)
        self._locale_id = 0

        if self._model_id != 0:
            self._model.disconnect(self._model_id)
            self._model_id = 0

        self._appsink = None

        LOG_MSG.info("Moonshine.destroy() called")
        super().destroy()

    def _stop_transcriber(self):
        """Stop and clean up the Moonshine transcriber."""
        if self._transcriber is not None:
            try:
                if self._transcriber_started:
                    self._transcriber.stop()
                    self._transcriber_started = False
                if self._listener is not None:
                    self._transcriber.remove_listener(self._listener)
            except Exception as e:
                LOG_MSG.error("Error stopping Moonshine transcriber: %s", e)
            self._transcriber = None
            self._listener = None

    def _load_moonshine_model(self, model_path, model_arch):
        """Load Moonshine model using moonshine-voice library."""
        if not MOONSHINE_AVAILABLE:
            LOG_MSG.error("moonshine-voice not available")
            return False

        try:
            LOG_MSG.info(
                "Loading Moonshine model: path=%s, arch=%s", model_path, model_arch
            )

            # Stop any existing transcriber
            self._stop_transcriber()

            # Determine options based on locale
            options = {}
            lang_code = None
            if self._current_locale and self._current_locale.locale:
                lang_code = self._current_locale.locale[:2]

            # For non-Latin script languages, increase token threshold
            # to avoid false hallucination detection
            if lang_code and lang_code in ('ar', 'ja', 'ko', 'zh', 'uk', 'vi'):
                options['max_tokens_per_second'] = '13.0'

            self._transcriber = Transcriber(
                model_path=model_path,
                model_arch=int(model_arch),
                options=options if options else None,
            )

            # Create and attach the event listener
            self._listener = _MoonshineListener(self._emit_text)
            self._transcriber.add_listener(self._listener)

            LOG_MSG.info("Moonshine model loaded successfully")
            return True

        except Exception as e:
            LOG_MSG.error("Failed to load Moonshine model: %s", e)
            self._transcriber = None
            self._listener = None
            return False

    def _set_model_path(self):
        if self._model is None or self._model.available() is False:
            LOG_MSG.info(
                "model path does not exist (%s - %s)",
                self._model.get_name() if self._model else "None",
                self._model.get_path() if self._model else "None",
            )
            self._stop_transcriber()
            self.emit("model-changed")
            return

        model_path = self._model.get_path()
        model_arch = self._model.get_arch()
        LOG_MSG.debug("model ready %s (arch=%s)", model_path, model_arch)

        # Pause pipeline while loading model
        ret, state, pending = self.pipeline.get_state(0)
        if state >= Gst.State.READY:
            self.pipeline.set_state(Gst.State.READY)

        success = self._load_moonshine_model(model_path, model_arch)

        if state >= Gst.State.READY:
            self.pipeline.set_state(state)

        if success:
            self.emit("model-changed")

    def _model_changed(self, model):
        self._set_model_path()

    def _set_model(self):
        if (
            self._model is not None
            and self._model.get_locale() == self._current_locale.locale
        ):
            return

        if self._model_id != 0:
            self._model.disconnect(self._model_id)
            self._model_id = 0

        self._model = STTMoonshineModel(locale_str=self._current_locale.locale)
        self._model_id = self._model.connect("changed", self._model_changed)
        self._set_model_path()

    def _locale_changed(self, locale):
        self._set_model()

    def _on_new_sample(self, appsink):
        """Callback when new audio sample arrives from GStreamer."""
        sample = appsink.emit("pull-sample")
        if sample is None:
            return Gst.FlowReturn.OK

        buf = sample.get_buffer()
        success, map_info = buf.map(Gst.MapFlags.READ)
        if not success:
            return Gst.FlowReturn.OK

        # Convert S16LE audio to float32 array for Moonshine
        audio_data = np.frombuffer(map_info.data, dtype=np.int16)
        buf.unmap(map_info)

        if self._transcriber is None:
            return Gst.FlowReturn.OK

        try:
            # Ensure transcriber session is started
            if not self._transcriber_started:
                self._transcriber.start()
                self._transcriber_started = True

            # Convert to float32 [-1.0, 1.0] as expected by Moonshine
            audio_float = audio_data.astype(np.float32) / 32768.0
            self._transcriber.add_audio(audio_float, self._sample_rate)

        except Exception as e:
            LOG_MSG.error("Error feeding audio to Moonshine: %s", e)

        return Gst.FlowReturn.OK

    def _emit_text(self, text):
        """Emit text signal on the GLib main thread."""
        self.emit("text", text)
        return False

    def get_final_results(self):
        """Force processing of any remaining audio."""
        if self._transcriber is not None and self._transcriber_started:
            try:
                self._transcriber.stop()
                self._transcriber_started = False
            except Exception as e:
                LOG_MSG.error("Error getting final Moonshine results: %s", e)

    def get_results(self):
        """Trigger a manual transcription update if needed."""
        if self._transcriber is not None and self._transcriber_started:
            try:
                self._transcriber.update_transcription()
            except Exception as e:
                LOG_MSG.error("Error updating Moonshine transcription: %s", e)

    def set_use_partial_results(self, active):
        # Moonshine's streaming models handle this natively via events
        pass

    def set_alternatives_num(self, num):
        # Not applicable for Moonshine
        pass

    def has_model(self):
        if self._model is None or self._model.available() is False:
            return False
        return super().has_model()

    def _stop_real(self):
        self.get_final_results()
        return super()._stop_real()

    def _start_real(self):
        """Start a new transcription session when pipeline starts."""
        result = super()._start_real()
        if result and self._transcriber is not None:
            try:
                if not self._transcriber_started:
                    self._transcriber.start()
                    self._transcriber_started = True
            except Exception as e:
                LOG_MSG.error("Error starting Moonshine transcriber: %s", e)
        return result



  -----------  Sttmoonshinemodel ----------------------

  """
IBus STT - Moonshine model settings manager

Manages the association between locales and Moonshine model paths/names,
persisting choices via GSettings and reacting to model availability changes
from the local model manager.
"""

import json
import logging

from pathlib import Path
from gi.repository import GObject, Gio
from sttmoonshinemodelmanagers import stt_moonshine_local_model_manager

LOG_MSG = logging.getLogger()


class STTMoonshineModel(GObject.Object):
    __gtype_name__ = "STTMoonshineModel"
    __gsignals__ = {
        "changed": (GObject.SIGNAL_RUN_FIRST, None, ()),
    }

    def __init__(self, locale_str=None):
        super().__init__()

        self._locale_str = locale_str
        self._settings = Gio.Settings.new("org.freedesktop.ibus.engine.stt")
        self._settings_id = self._settings.connect(
            "changed::moonshine-models", self._models_changed
        )

        self._model_name = None
        self._model_path = None
        self._model_arch = None
        self._valid_model = False

        model = self._get_model_from_settings()
        self._set_model(model)

        self._model_path_added_id = stt_moonshine_local_model_manager().connect(
            "added", self._model_added_cb
        )
        self._model_path_removed_id = stt_moonshine_local_model_manager().connect(
            "removed", self._model_removed_cb
        )

    def __del__(self):
        stt_moonshine_local_model_manager().disconnect(self._model_path_added_id)
        stt_moonshine_local_model_manager().disconnect(self._model_path_removed_id)
        if self._model_name is None and self._model_path is not None:
            stt_moonshine_local_model_manager().unregister_custom_model_path(
                self._model_path
            )

    def _get_model_from_settings(self):
        models_json_string = self._settings.get_string("moonshine-models")
        if models_json_string in (None, "None", ""):
            return None

        models_dict = json.loads(models_json_string)
        return models_dict.get(self._locale_str, None)

    def _set_model(self, model):
        LOG_MSG.debug(
            "new model (%s, current path=%s / current name=%s)",
            model,
            self._model_path,
            self._model_name,
        )
        if model is None:
            if self._model_name is None and self._model_path is None:
                return

            self._model_name = None
            self._model_path = None
            self._model_arch = None
            self._valid_model = False

            self.emit("changed")
            return

        model = model.rstrip("/")
        model_name = self._model_name
        model_path = self._model_path

        if Path(model).is_absolute() is True:
            # Custom absolute path to a model directory
            if self._model_name is None and self._model_path == model:
                return

            self._model_name = None
            self._model_path = model
            stt_moonshine_local_model_manager().register_custom_model_path(
                model, self._locale_str
            )
            self._valid_model = stt_moonshine_local_model_manager().path_available(
                model
            )
            if self._valid_model:
                desc = stt_moonshine_local_model_manager().get_model_description_by_path(model)
                if desc is not None:
                    self._model_arch = desc.arch
        else:
            # Named model (e.g., "base-en")
            tmp_model_path = stt_moonshine_local_model_manager().get_best_path_for_model(
                model
            )
            if self._model_name == model and tmp_model_path == model_path:
                return

            self._model_name = model
            self._model_path = tmp_model_path
            self._valid_model = bool(tmp_model_path is not None)

            if self._valid_model:
                desc = stt_moonshine_local_model_manager().get_model_description(model)
                if desc is not None:
                    self._model_arch = desc.arch

        if model_path not in [self._model_path, None] and model_name is None:
            stt_moonshine_local_model_manager().unregister_custom_model_path(model_path)

        LOG_MSG.debug(
            "model changed (valid=%i, path=%s, name=%s, arch=%s)",
            self._valid_model,
            self._model_path,
            self._model_name,
            self._model_arch,
        )
        self.emit("changed")

    def _models_changed(self, settings, key):
        model = self._get_model_from_settings()
        self._set_model(model)

    def _model_added_cb(self, manager, name, path):
        if self._model_name is not None:
            if name != self._model_name:
                return

            model_path = stt_moonshine_local_model_manager().get_best_path_for_model(
                name
            )
            if self._model_path == model_path:
                return

            self._model_path = model_path
        elif self._model_path != path:
            return

        self._valid_model = True

        # Update arch info
        desc = None
        if self._model_name:
            desc = stt_moonshine_local_model_manager().get_model_description(
                self._model_name
            )
        else:
            desc = stt_moonshine_local_model_manager().get_model_description_by_path(
                self._model_path
            )
        if desc is not None:
            self._model_arch = desc.arch

        self.emit("changed")

    def _model_removed_cb(self, manager, name, path):
        if self._model_name is not None:
            if name != self._model_name:
                return

            if self._model_path != path:
                return

            self._model_path = stt_moonshine_local_model_manager().get_best_path_for_model(
                name
            )
            self._valid_model = bool(self._model_path is not None)
        elif self._model_path == path:
            self._valid_model = False
        else:
            return

        self.emit("changed")

    def available(self):
        return self._valid_model

    def get_locale(self):
        return self._locale_str

    def get_name(self):
        return self._model_name

    def get_path(self):
        return self._model_path

    def get_arch(self):
        """Return the model architecture integer for Moonshine Transcriber."""
        return self._model_arch

    def set_name(self, model_name):
        self._set_model(model_name)

        models_json_string = self._settings.get_string("moonshine-models")
        if models_json_string in (None, "None", ""):
            models_dict = {}
        else:
            models_dict = json.loads(models_json_string)

        models_dict[self._locale_str] = model_name
        models_json_string = json.dumps(models_dict)

        self._settings.disconnect(self._settings_id)
        self._settings.set_string("moonshine-models", models_json_string)
        self._settings_id = self._settings.connect(
            "changed::moonshine-models", self._models_changed
        )



---------  Sttmoonshinemodelmanagers  -------------


"""
IBus STT - Moonshine model managers

Manages discovery, downloading, and lifecycle of Moonshine ASR models.

Key differences from Whisper models:
- Moonshine models are *directories* containing multiple files:
  encoder_model.ort, decoder_model_merged.ort, tokenizer.bin
- Models are language-specific (e.g., base-en, base-ja) rather than multilingual
- Downloads use the moonshine_voice.download module when available
- Model architectures are identified by integer IDs from moonshine-c-api.h
"""

import os
import json
import logging
import threading
import uuid
from pathlib import Path
from enum import Enum

from gi.repository import GObject, Gio, GLib

LOG_MSG = logging.getLogger()

# Try importing moonshine download utilities
try:
    from moonshine_voice.download import download_model
    MOONSHINE_DOWNLOAD_AVAILABLE = True
except ImportError:
    MOONSHINE_DOWNLOAD_AVAILABLE = False
    LOG_MSG.debug("moonshine_voice.download not available for model downloading")

# Required files in a valid Moonshine model directory
REQUIRED_MODEL_FILES = [
    "encoder_model.ort",
    "decoder_model_merged.ort",
    "tokenizer.bin",
]

# Standard directories to scan for Moonshine models
_home_cache = Path.home() / ".cache" / "moonshine_voice"
MODEL_DIRS = [
    os.getenv("MOONSHINE_VOICE_CACHE"),
    str(_home_cache),
    "/usr/share/moonshine",
    "/usr/local/share/moonshine",
]

# Language code to full name mapping (for moonshine_voice.download)
LANGUAGE_MAP = {
    "en": "english",
    "ar": "arabic",
    "ja": "japanese",
    "ko": "korean",
    "zh": "mandarin",
    "es": "spanish",
    "uk": "ukrainian",
    "vi": "vietnamese",
}

# Known Moonshine models catalog
# name -> (language_code, size_str, arch_hint)
# arch values: the download module returns the correct arch, these are defaults
MOONSHINE_MODELS = {
    "tiny-en":              ("en", "26 MB",  0),
    "tiny-streaming-en":    ("en", "34 MB",  2),
    "base-en":              ("en", "58 MB",  1),
    "small-streaming-en":   ("en", "123 MB", 3),
    "medium-streaming-en":  ("en", "245 MB", 4),
    "base-ar":              ("ar", "58 MB",  1),
    "base-ja":              ("ja", "58 MB",  1),
    "tiny-ko":              ("ko", "26 MB",  0),
    "base-zh":              ("zh", "58 MB",  1),
    "base-es":              ("es", "58 MB",  1),
    "base-uk":              ("uk", "58 MB",  1),
    "base-vi":              ("vi", "58 MB",  1),
}

DOWNLOADED_MODEL_SUFFIX = ".downloading_tmp"


def _is_valid_moonshine_model_dir(dir_path):
    """Check if a directory contains the required Moonshine model files."""
    p = Path(dir_path)
    if not p.is_dir():
        return False
    return all((p / f).is_file() for f in REQUIRED_MODEL_FILES)


def _detect_model_info(model_dir_path):
    """Try to detect model name, language, and arch from directory path/name."""
    dir_name = Path(model_dir_path).name
    parent_parts = Path(model_dir_path).parts

    # Try to match against known models
    for model_name, (lang, size, arch) in MOONSHINE_MODELS.items():
        if dir_name == model_name or dir_name.endswith(model_name):
            return model_name, lang, arch

    # Try to infer language from directory name pattern like "base-en"
    lang_code = None
    if "-" in dir_name:
        suffix = dir_name.split("-")[-1]
        if suffix in LANGUAGE_MAP:
            lang_code = suffix

    # Try to detect from parent path (moonshine download cache structure)
    # e.g., .cache/moonshine_voice/download.moonshine.ai/model/base-en/quantized/base-en
    for part in parent_parts:
        for model_name, (lang, size, arch) in MOONSHINE_MODELS.items():
            if part == model_name:
                return model_name, lang, arch

    return dir_name, lang_code, None


class STTDownloadState(float, Enum):
    STOPPED = -1.0
    UNKNOWN_PROGRESS = -0.5
    UNPACKING = -0.6
    ONGOING = 0.0


class STTMoonshineModelDescription(GObject.Object):
    __gtype_name__ = "STTMoonshineModelDescription"

    def __init__(self, init_model=None):
        super().__init__()
        self.name = init_model.name if init_model is not None else ""
        self.custom = init_model.custom if init_model is not None else False
        self.is_obsolete = False
        self.paths = init_model.paths if init_model is not None else []
        self.size = init_model.size if init_model is not None else ""
        self.type = init_model.type if init_model is not None else ""
        self.locale = init_model.locale if init_model is not None else ""
        self.url = init_model.url if init_model is not None else ""
        self.arch = init_model.arch if init_model is not None else None

        self._operation = None
        self.download_progress = STTDownloadState.STOPPED

    def _download_finished(self):
        if self._operation is not None and self._operation.is_cancelled():
            self._operation = None

    def _download_model_thread(self, model_name, language, status):
        """Download a Moonshine model using the moonshine_voice library."""
        try:
            if not MOONSHINE_DOWNLOAD_AVAILABLE:
                LOG_MSG.error(
                    "moonshine_voice.download not available. "
                    "Install moonshine-voice to enable model downloading."
                )
                self.download_progress = STTDownloadState.STOPPED
                return

            self.download_progress = STTDownloadState.UNKNOWN_PROGRESS

            if status.is_cancelled():
                self.download_progress = STTDownloadState.STOPPED
                return

            LOG_MSG.info(
                "Downloading Moonshine model: name=%s, language=%s",
                model_name, language,
            )

            # Use the moonshine_voice download module
            # This downloads to the default cache directory
            model_path, model_arch = download_model(language=language)

            if status.is_cancelled():
                self.download_progress = STTDownloadState.STOPPED
                return

            if model_path and Path(model_path).is_dir():
                self.arch = model_arch
                LOG_MSG.info(
                    "Model downloaded: path=%s, arch=%s", model_path, model_arch
                )
            else:
                LOG_MSG.error("Download completed but model path invalid: %s", model_path)

        except Exception as e:
            LOG_MSG.error("Download error: %s", e)

        self.download_progress = STTDownloadState.STOPPED
        GLib.idle_add(self._download_finished)

    def stop_downloading(self):
        if self._operation is not None:
            self._operation.cancel()

    def start_downloading(self):
        if self._operation is not None:
            return

        lang_code = self.locale if self.locale else "en"
        language = LANGUAGE_MAP.get(lang_code, lang_code)

        LOG_MSG.debug("start downloading Moonshine model (%s, lang=%s)", self.name, language)

        self.download_progress = STTDownloadState.ONGOING
        self._operation = Gio.Cancellable()

        download_thread = threading.Thread(
            target=self._download_model_thread,
            args=(self.name, language, self._operation),
            daemon=True,
        )
        download_thread.start()

    def get_best_path_for_model(self):
        if self.paths in [None, []]:
            return None
        return self.paths[0]

    def delete_paths(self):
        if self.custom is True:
            return

        for path in self.paths:
            model_dir = Path(path)
            # Only delete from the user cache directory
            if str(model_dir).startswith(str(_home_cache)):
                try:
                    if model_dir.is_dir():
                        import shutil
                        shutil.rmtree(model_dir)
                    elif model_dir.is_file():
                        model_dir.unlink()
                except Exception as e:
                    LOG_MSG.error("Failed to delete %s: %s", path, e)

        self._operation = None
        self.download_progress = STTDownloadState.STOPPED
        self.paths = []


class STTMoonshineLocalModelManager(GObject.Object):
    __gtype_name__ = "STTMoonshineLocalModelManager"

    __gsignals__ = {
        "added": (GObject.SIGNAL_RUN_FIRST, None, (str, str)),
        "removed": (GObject.SIGNAL_RUN_FIRST, None, (str, str)),
    }

    def __init__(self):
        super().__init__()
        self._monitors = []
        self._models_dict = {}       # model_name -> model_desc
        self._locales_dict = {}      # locale -> [model_desc, ...]
        self._model_paths_dict = {}  # path_str -> model_desc
        self._custom_paths = {}
        self._get_available_local_models()

    def _add_model_description_to_locale(self, model_desc):
        if model_desc.locale is None:
            return

        models_list = self._locales_dict.get(model_desc.locale, None)
        if models_list is None:
            self._locales_dict[model_desc.locale] = [model_desc]
        else:
            if model_desc not in models_list:
                models_list.append(model_desc)

    def _new_model_available(self, model_path):
        """Register a newly discovered Moonshine model directory."""
        model_path = Path(model_path)

        if str(model_path).endswith(DOWNLOADED_MODEL_SUFFIX):
            LOG_MSG.debug("model path is a temporary file (%s)", model_path)
            return None

        if not _is_valid_moonshine_model_dir(model_path):
            LOG_MSG.debug("not a valid Moonshine model directory (%s)", model_path)
            return None

        if not os.access(model_path, os.R_OK):
            LOG_MSG.debug("access rights are wrong (%s)", model_path)
            return None

        path_str = str(model_path)
        if self.path_available(path_str):
            LOG_MSG.debug("model directory already in list (%s)", model_path)
            return None

        model_name, lang_code, arch = _detect_model_info(model_path)

        # Check if this is a custom path (not in standard dirs)
        is_in_standard_dir = False
        for d in MODEL_DIRS:
            if d and path_str.startswith(str(d)):
                is_in_standard_dir = True
                break

        if not is_in_standard_dir:
            # Custom model
            model_desc = STTMoonshineModelDescription()
            model_desc.paths = [path_str]
            model_desc.name = model_name
            model_desc.custom = True
            model_desc.locale = lang_code
            model_desc.arch = arch

            self._models_dict[path_str] = model_desc
            self._model_paths_dict[path_str] = model_desc

            LOG_MSG.debug("custom Moonshine model found (%s)", model_path)
            return model_desc

        # Standard model
        model_desc = self._models_dict.get(model_name, None)
        if model_desc is None:
            model_desc = STTMoonshineModelDescription()
            model_desc.paths = [path_str]
            model_desc.locale = lang_code
            model_desc.name = model_name
            model_desc.arch = arch

            # Look up size from catalog
            if model_name in MOONSHINE_MODELS:
                _, size, catalog_arch = MOONSHINE_MODELS[model_name]
                model_desc.size = size
                if model_desc.arch is None:
                    model_desc.arch = catalog_arch

            self._add_model_description_to_locale(model_desc)
            self._models_dict[model_name] = model_desc
            self._model_paths_dict[path_str] = model_desc

            LOG_MSG.debug("Moonshine model found (%s) - new", model_path)
            self.emit("added", model_name, path_str)
            return model_desc

        # Already known model name, add this path
        if path_str not in model_desc.paths:
            model_desc.paths.append(path_str)

        self._model_paths_dict[path_str] = model_desc

        LOG_MSG.debug("Moonshine model found (%s) - already known", model_path)
        self.emit("added", model_name, path_str)
        return model_desc

    def _remove_model_description(self, model_path_str):
        model_desc = self._model_paths_dict.pop(model_path_str, None)
        if model_desc is None:
            return

        LOG_MSG.debug("model removed (%s)", model_path_str)

        if model_path_str in model_desc.paths:
            model_desc.paths.remove(model_path_str)

        if not any(model_desc.paths):
            models_list = self._locales_dict.get(model_desc.locale, [])
            if model_desc in models_list:
                models_list.remove(model_desc)
            if not any(models_list):
                self._locales_dict.pop(model_desc.locale, None)

            key = model_desc.name if not model_desc.custom else model_path_str
            self._models_dict.pop(key, None)

        model_name = model_desc.name if not model_desc.custom else None
        self.emit("removed", model_name, model_path_str)

    def _model_dir_changed_cb(self, monitor, file, other_file, event_type):
        """Handle filesystem changes in model directories."""
        file_path = file.get_path()

        # Skip top-level directory events
        if file_path in [str(d) for d in MODEL_DIRS if d]:
            return

        LOG_MSG.info(
            "a model directory changed (%s) (event=%s)", file_path, event_type
        )

        if event_type == Gio.FileMonitorEvent.CHANGES_DONE_HINT:
            if file_path.endswith(DOWNLOADED_MODEL_SUFFIX):
                return
            # For Moonshine, we need to check the parent directory
            # since models are directories, not single files
            path = Path(file_path)
            # Check if the changed file's parent is a valid model dir
            if _is_valid_moonshine_model_dir(path.parent):
                self._new_model_available(path.parent)
            elif _is_valid_moonshine_model_dir(path):
                self._new_model_available(path)

        elif event_type == Gio.FileMonitorEvent.DELETED:
            self._remove_model_description(file_path)

    def _scan_directory_recursive(self, directory_path):
        """Scan a directory for Moonshine model subdirectories."""
        if not directory_path.is_dir():
            return

        # Check if this directory itself is a model
        if _is_valid_moonshine_model_dir(directory_path):
            self._new_model_available(directory_path)
            return

        # Scan children (model dirs are usually 1-2 levels deep)
        for child in directory_path.iterdir():
            if child.is_dir():
                if _is_valid_moonshine_model_dir(child):
                    self._new_model_available(child)
                else:
                    # Go one more level for cache structures like
                    # .cache/moonshine_voice/download.moonshine.ai/model/base-en/quantized/base-en
                    for grandchild in child.iterdir():
                        if grandchild.is_dir():
                            if _is_valid_moonshine_model_dir(grandchild):
                                self._new_model_available(grandchild)
                            else:
                                for ggchild in grandchild.iterdir():
                                    if ggchild.is_dir():
                                        if _is_valid_moonshine_model_dir(ggchild):
                                            self._new_model_available(ggchild)

    def _get_available_local_models(self):
        """Scan all model directories for available models."""
        for directory in MODEL_DIRS:
            LOG_MSG.debug("scanning %s for Moonshine models", directory)

            if directory is None:
                continue

            dir_path = Path(directory)

            # Set up file monitoring
            monitor = Gio.File.new_for_path(str(dir_path)).monitor_directory(
                Gio.FileMonitorFlags.NONE, None
            )
            if monitor is not None:
                monitor.connect("changed", self._model_dir_changed_cb)
                self._monitors.append(monitor)

            self._scan_directory_recursive(dir_path)

    def path_available(self, model_path):
        return model_path in self._model_paths_dict

    def get_models_for_locale(self, locale_str):
        return self._locales_dict.get(locale_str, []).copy()

    def get_best_path_for_model(self, model_name):
        if model_name is None:
            return None

        model = self._models_dict.get(model_name, None)
        if model is None:
            return None

        if model.paths in [None, []]:
            return None

        return model.paths[0]

    def get_model_description(self, model_name):
        return self._models_dict.get(model_name, None)

    def get_model_description_by_path(self, model_path):
        return self._model_paths_dict.get(model_path, None)

    def get_supported_locales(self):
        return list(self._locales_dict.keys())

    def _custom_model_dir_changed_cb(self, monitor, file, other_file, event_type):
        file_path = file.get_path()
        LOG_MSG.info(
            "custom model changed (%s) (event=%s)", file_path, event_type
        )
        if event_type == Gio.FileMonitorEvent.CHANGES_DONE_HINT:
            path = Path(file_path)
            if _is_valid_moonshine_model_dir(path):
                self._new_model_available(path)
            elif _is_valid_moonshine_model_dir(path.parent):
                self._new_model_available(path.parent)

        elif event_type == Gio.FileMonitorEvent.DELETED:
            model = self._model_paths_dict.get(file_path, None)
            if model is None:
                return
            self._model_paths_dict.pop(file_path, None)
            self.emit("removed", None, file_path)

    def register_custom_model_path(self, model_path_str, locale_str):
        """Register a custom model path outside standard directories."""
        # Check if it's in a standard directory
        for d in MODEL_DIRS:
            if d and model_path_str.startswith(str(d)):
                LOG_MSG.debug(
                    "registered path is in standard directory (%s)", model_path_str
                )
                return

        monitor = self._custom_paths.get(model_path_str, None)
        if monitor is not None:
            monitor.refcount += 1
            LOG_MSG.debug(
                "custom path already registered (%s). refcount=%i",
                model_path_str,
                monitor.refcount,
            )
            return

        # Monitor the directory for changes
        monitor = Gio.File.new_for_path(model_path_str).monitor_directory(
            Gio.FileMonitorFlags.NONE, None
        )
        if monitor is not None:
            monitor.connect("changed", self._custom_model_dir_changed_cb)
            self._custom_paths[model_path_str] = monitor
            monitor.refcount = 1

        model_desc = self._new_model_available(Path(model_path_str))
        if model_desc:
            model_desc.locale = locale_str
            self._add_model_description_to_locale(model_desc)
            self.emit("added", None, model_path_str.rstrip("/"))

    def unregister_custom_model_path(self, model_path_str):
        monitor = self._custom_paths.get(model_path_str, None)
        if monitor is None:
            LOG_MSG.debug(
                "trying to unregister unknown custom path (%s)", model_path_str
            )
            return

        if monitor.refcount != 1:
            monitor.refcount -= 1
            return

        self._custom_paths.pop(model_path_str, None)
        self._remove_model_description(model_path_str)


_GLOBAL_LOCAL_MANAGER = None


def stt_moonshine_local_model_manager():
    global _GLOBAL_LOCAL_MANAGER
    if _GLOBAL_LOCAL_MANAGER is None:
        _GLOBAL_LOCAL_MANAGER = STTMoonshineLocalModelManager()
    return _GLOBAL_LOCAL_MANAGER


class STTMoonshineOnlineModelManager(GObject.Object):
    __gtype_name__ = "STTMoonshineOnlineModelManager"
    __gsignals__ = {
        "added": (GObject.SIGNAL_RUN_FIRST, None, (object,)),
        "changed": (GObject.SIGNAL_RUN_FIRST, None, (object,)),
        "removed": (GObject.SIGNAL_RUN_FIRST, None, (object,)),
    }

    def __init__(self):
        super().__init__()

        self._locales_dict = {}
        self._online_models = {}

        local_manager = stt_moonshine_local_model_manager()
        local_manager.connect("added", self._model_path_added_cb)
        local_manager.connect("removed", self._model_path_removed_cb)
        self._populate_with_moonshine_models()

    def _populate_with_moonshine_models(self):
        """Populate the catalog with known Moonshine models."""
        for model_name, (lang_code, size, arch) in MOONSHINE_MODELS.items():
            model_desc = STTMoonshineModelDescription()
            model_desc.name = model_name
            model_desc.size = size
            model_desc.locale = lang_code
            model_desc.arch = arch

            # Determine model type (architecture variant)
            if "streaming" in model_name:
                parts = model_name.split("-")
                # e.g., "small-streaming-en" -> type "small-streaming"
                model_desc.type = "-".join(parts[:-1])
            else:
                model_desc.type = model_name.split("-")[0]

            # Check if already downloaded locally
            local_desc = stt_moonshine_local_model_manager().get_model_description(
                model_name
            )
            if local_desc is not None:
                model_desc.paths = local_desc.paths
                if local_desc.arch is not None:
                    model_desc.arch = local_desc.arch

            if model_name in self._online_models:
                existing = self._online_models[model_name]
                if not existing.paths and model_desc.paths:
                    existing.paths = model_desc.paths
                continue

            self._online_models[model_name] = model_desc
            self._add_model_description_to_locale(model_desc)

        # Also add any locally-found models not in the catalog
        for locale in stt_moonshine_local_model_manager().get_supported_locales():
            model_list = stt_moonshine_local_model_manager().get_models_for_locale(
                locale
            )
            for model_desc in model_list:
                key = model_desc.name if not model_desc.custom else model_desc.paths[0]
                if key in self._online_models:
                    continue

                LOG_MSG.debug("adding local-only model to catalog (%s)", key)
                self._online_models[key] = model_desc
                self._add_model_description_to_locale(model_desc)

    def _add_model_description_to_locale(self, model_desc):
        locale_models = self._locales_dict.get(model_desc.locale, None)
        if locale_models is None:
            self._locales_dict[model_desc.locale] = [model_desc]
        else:
            if model_desc not in locale_models:
                locale_models.append(model_desc)

    def _model_path_added_cb(self, manager, model_name, model_path):
        if model_name is not None:
            online_model_desc = self._online_models.get(model_name, None)
            local_model_desc = manager.get_model_description(model_name)
        else:
            online_model_desc = self._online_models.get(model_path, None)
            local_model_desc = manager.get_model_description_by_path(model_path)

        if local_model_desc is None:
            return

        if online_model_desc is not None:
            if online_model_desc.paths in [None, []]:
                online_model_desc.paths = local_model_desc.paths
            if local_model_desc.arch is not None:
                online_model_desc.arch = local_model_desc.arch

            self.emit("changed", online_model_desc)
            return

        key = (
            local_model_desc.name
            if not local_model_desc.custom
            else local_model_desc.paths[0]
        )
        self._online_models[key] = local_model_desc
        self._add_model_description_to_locale(local_model_desc)
        self.emit("added", local_model_desc)

    def _remove_model_description_from_locale(self, model_desc):
        locale_models = self._locales_dict.get(model_desc.locale, None)
        if locale_models and model_desc in locale_models:
            locale_models.remove(model_desc)
        if locale_models is not None and not any(locale_models):
            self._locales_dict.pop(model_desc.locale, None)

    def _model_path_removed_cb(self, manager, model_name, model_path):
        if model_name is None:
            online_model_desc = self._online_models.pop(model_path, None)
            if online_model_desc:
                self._remove_model_description_from_locale(online_model_desc)
                self.emit("removed", online_model_desc)
            return

        online_model_desc = self._online_models.get(model_name, None)
        if online_model_desc is None:
            return

        if any(online_model_desc.paths):
            self.emit("changed", online_model_desc)
            return

        # Keep catalog entries (they can be re-downloaded)
        if model_name in MOONSHINE_MODELS:
            self.emit("changed", online_model_desc)
            return

        self._online_models.pop(model_name, None)
        self._remove_model_description_from_locale(online_model_desc)
        self.emit("removed", online_model_desc)

    def get_model_description(self, model_name):
        return self._online_models.get(model_name, None)

    def get_models_for_locale(self, locale_str):
        return self._locales_dict.get(locale_str, []).copy()

    def supported_locales(self):
        return list(self._locales_dict.keys())


_GLOBAL_ONLINE_MANAGER = None


def stt_moonshine_online_model_manager():
    global _GLOBAL_ONLINE_MANAGER
    if _GLOBAL_ONLINE_MANAGER is None:
        _GLOBAL_ONLINE_MANAGER = STTMoonshineOnlineModelManager()
    return _GLOBAL_ONLINE_MANAGER


-------------  moonshine integration -----------

# Moonshine ASR Integration into IBus Speech-to-Text

## Overview

This integration adds Moonshine Voice as a third speech recognition backend
for ibus-stt, alongside the existing Vosk and WhisperCpp backends.

### Why Moonshine?

Moonshine is purpose-built for **live speech** with key advantages:
- **Streaming support**: Does work while the user is still talking, so results
  arrive almost instantly when speech ends (34ms–802ms latency vs Whisper's 1–17s).
- **Flexible input windows**: No fixed 30-second window like Whisper; processes
  only the actual speech duration.
- **Language-specific models**: Trained per-language for higher accuracy at
  smaller sizes (e.g., 6.65% WER English with 245M params vs Whisper Large V3's
  7.44% WER with 1.5B params).
- **Event-driven API**: Native `TranscriptEventListener` pattern maps cleanly
  to ibus-stt's GObject signal architecture.

## Files

### New files (copy to `engine/`)

| File | Purpose |
|------|---------|
| `sttgstmoonshine.py` | GStreamer pipeline → Moonshine Transcriber bridge |
| `sttmoonshinemodel.py` | GSettings-backed model path/name persistence |
| `sttmoonshinemodelmanagers.py` | Local model scanning + online catalog + download |

### Modified files (see `moonshine-integration.patch`)

| File | Change |
|------|--------|
| `gschema.xml.in` | Add `moonshine-models` GSettings key |
| `meson.build` | Register new source files |
| `sttconfigdialog.py` | Add "Moonshine" as backend index 2 |
| `sttconfigdialog.ui` | Add "Moonshine" to GtkStringList dropdown |
| `sttgstfactory.py` | Instantiate `STTGstMoonshine` for backend="moonshine" |
| `sttlocalerow.py` | Use `STTMoonshineModel` when backend is moonshine |
| `sttmodelchooserdialog.py` | Support Moonshine model chooser (folder selection) |

## Dependencies

```bash
pip install moonshine-voice numpy
```

The `moonshine-voice` package includes the core C++ library via OnnxRuntime,
plus Python bindings for `Transcriber`, `TranscriptEventListener`, and model
download utilities.

## Model Management

### Key difference from Whisper

Moonshine models are **directories** (not single files) containing:
```
model-directory/
├── encoder_model.ort
├── decoder_model_merged.ort
└── tokenizer.bin
```

### Downloading models

```bash
# From terminal (recommended first-time setup)
pip install moonshine-voice
python -m moonshine_voice.download --language en

# Supported languages: en, ar, ja, ko, zh (mandarin), es, uk, vi
```

Models are cached in `~/.cache/moonshine_voice/` by default.
Set `MOONSHINE_VOICE_CACHE` environment variable to customize.

### Model scan directories

The manager scans these directories recursively:
1. `$MOONSHINE_VOICE_CACHE` (if set)
2. `~/.cache/moonshine_voice/`
3. `/usr/share/moonshine/`
4. `/usr/local/share/moonshine/`

### Available models

| Language   | Model Name           | Size    | Parameters  |
|------------|---------------------|---------|-------------|
| English    | tiny-en             | 26 MB   | 26 million  |
| English    | tiny-streaming-en   | 34 MB   | 34 million  |
| English    | base-en             | 58 MB   | 58 million  |
| English    | small-streaming-en  | 123 MB  | 123 million |
| English    | medium-streaming-en | 245 MB  | 245 million |
| Arabic     | base-ar             | 58 MB   | 58 million  |
| Japanese   | base-ja             | 58 MB   | 58 million  |
| Korean     | tiny-ko             | 26 MB   | 26 million  |
| Mandarin   | base-zh             | 58 MB   | 58 million  |
| Spanish    | base-es             | 58 MB   | 58 million  |
| Ukrainian  | base-uk             | 58 MB   | 58 million  |
| Vietnamese | base-vi             | 58 MB   | 58 million  |

Streaming models (tiny-streaming, small-streaming, medium-streaming) provide
the lowest latency for live speech by caching encoder state incrementally.

## Architecture Notes

### How sttgstmoonshine.py works

```
PulseAudio → GStreamer appsink (S16LE, 16kHz, mono)
    │
    ▼
_on_new_sample(): convert int16 → float32
    │
    ▼
Moonshine Transcriber.add_audio(float32[], 16000)
    │
    ▼
_MoonshineListener.on_line_completed(event)
    │
    ▼
GLib.idle_add → emit("text", transcribed_text)
    │
    ▼
IBus engine commits text
```

Unlike the Whisper integration (which buffers 2–6 seconds then batch-processes),
Moonshine's streaming architecture processes audio incrementally via `add_audio()`.
The `Transcriber` handles VAD segmentation, caching, and text extraction internally,
and calls `on_line_completed()` when a phrase ends.

### Non-Latin language handling

For languages using non-Latin scripts (ar, ja, ko, zh, uk, vi), the engine
automatically sets `max_tokens_per_second=13.0` to prevent false hallucination
detection, as documented in the Moonshine API.

## Testing

1. Install dependencies:
   ```bash
   pip install moonshine-voice numpy
   python -m moonshine_voice.download --language en
   ```

2. Apply the patch and copy new files to `engine/`.

3. Rebuild with meson:
   ```bash
   meson setup build
   meson compile -C build
   ```

4. Recompile GSettings schemas:
   ```bash
   glib-compile-schemas /usr/share/glib-2.0/schemas/
   ```

5. Set backend to moonshine:
   ```bash
   gsettings set org.freedesktop.ibus.engine.stt backend 'moonshine'
   ```

6. Or use the IBus STT Setup GUI → select "Moonshine" from the
   "Recognition Backend" dropdown.

## License

Moonshine English models: MIT License.
Moonshine non-English models: Moonshine Community License (non-commercial).





  
