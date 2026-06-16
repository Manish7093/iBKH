
From 0000000000000000000000000000000000000000 Mon Sep 17 00:00:00 2001
From: Itachi <itachi@example.com>
Date: Mon, 16 Jun 2026 00:00:00 +0530
Subject: [PATCH] Add Moonshine ASR backend

Integrate the Moonshine streaming speech-recognition engine
(moonshine_voice) as a third backend alongside Vosk and Whisper.

 - sttgstmoonshine.py: STTGstBase subclass feeding the appsink chunks
   straight into a Moonshine Transcriber (built-in VAD/streaming, so no
   manual windowing or in-tree VAD); a worker thread drives start()/
   add_audio()/stop() and marshals completed lines back via GLib.idle_add.
 - sttmoonshinemodel.py: GObject model persisting the per-locale
   selection in the new "moonshine-models" gsettings key (model name or
   absolute custom-folder path); exposes get_arch().
 - sttmoonshinemodelmanagers.py: local + online managers built from
   moonshine_voice.download.MODEL_INFO; downloads/paths resolved through
   Moonshine's own cache (get_model_for_language), import-guarded so the
   UI still loads when moonshine_voice is absent.
 - Wire the backend through the factory, config dialog (third radio
   option, model info, locale list, no voice commands), locale row,
   model chooser (folder selection) and model row.

Runtime dependency: pip install moonshine-voice
---
diff --git a/engine/sttconfigdialog.py b/engine/sttconfigdialog.py
index 7ed7f1a..3c68468 100644
--- a/engine/sttconfigdialog.py
+++ b/engine/sttconfigdialog.py
@@ -18,12 +18,15 @@ from sttshortcutdialog import STTShortcutDialog
 from sttcurrentlocale import stt_current_locale
 from sttvoskmodelmanagers import stt_vosk_online_model_manager
 from sttwhispermodelmanagers import stt_whisper_online_model_manager
+from sttmoonshinemodelmanagers import stt_moonshine_online_model_manager
 from sttvoskmodel import STTVoskModel
 from sttwhispermodel import STTWhisperModel
+from sttmoonshinemodel import STTMoonshineModel
 from sttmodelchooserdialog import STTModelChooserDialog
 
 from sttgstvosk import STTGstVosk
 from sttgstwhisper import STTGstWhisper
+from sttgstmoonshine import STTGstMoonshine
 
 LOG_MSG=logging.getLogger()
 
@@ -37,6 +40,7 @@ class STTConfigDialog (Adw.Window):
 
     vosk_check    = Gtk.Template.Child()
     whisper_check = Gtk.Template.Child()
+    moonshine_check = Gtk.Template.Child()
 
     tab_stack    = Gtk.Template.Child()
     tab_switcher = Gtk.Template.Child()
@@ -86,6 +90,7 @@ class STTConfigDialog (Adw.Window):
 
         stt_vosk_online_model_manager()
         stt_whisper_online_model_manager()
+        stt_moonshine_online_model_manager()
 
         # Load current locale
         self._current_locale = stt_current_locale()
@@ -97,6 +102,8 @@ class STTConfigDialog (Adw.Window):
         self._suppress_engine_cb = True
         if backend == "whisper":
             self.whisper_check.set_active(True)
+        elif backend == "moonshine":
+            self.moonshine_check.set_active(True)
         else:
             self.vosk_check.set_active(True)
         self._suppress_engine_cb = False
@@ -151,6 +158,8 @@ class STTConfigDialog (Adw.Window):
         backend = self._settings.get_string("backend")
         if backend == "whisper":
             self._engine = STTGstWhisper(current_locale=self._current_locale)
+        elif backend == "moonshine":
+            self._engine = STTGstMoonshine(current_locale=self._current_locale)
         else:
             self._engine = STTGstVosk(current_locale=self._current_locale)
 
@@ -168,7 +177,13 @@ class STTConfigDialog (Adw.Window):
                 and self._current_locale.locale not in self._locale_list):
             self._append_locale_option(self._current_locale.locale)
 
-        supported = stt_vosk_online_model_manager().supported_locales()
+        backend = self._settings.get_string("backend")
+        if backend == "whisper":
+            supported = stt_whisper_online_model_manager().supported_locales()
+        elif backend == "moonshine":
+            supported = stt_moonshine_online_model_manager().supported_locales()
+        else:
+            supported = stt_vosk_online_model_manager().supported_locales()
         _EXCLUDED = {"multilingual"}
 
         for loc in sorted(supported):
@@ -218,6 +233,8 @@ class STTConfigDialog (Adw.Window):
 
         if backend == "whisper":
             self._model = STTWhisperModel(locale_str=locale_str)
+        elif backend == "moonshine":
+            self._model = STTMoonshineModel(locale_str=locale_str)
         else:
             self._model = STTVoskModel(locale_str=locale_str)
 
@@ -244,13 +261,30 @@ class STTConfigDialog (Adw.Window):
             return
 
         backend = self._settings.get_string("backend")
-        manager = (stt_whisper_online_model_manager() if backend == "whisper"
-                   else stt_vosk_online_model_manager())
+        if backend == "whisper":
+            manager = stt_whisper_online_model_manager()
+        elif backend == "moonshine":
+            manager = stt_moonshine_online_model_manager()
+        else:
+            manager = stt_vosk_online_model_manager()
         desc = manager.get_model_description(model_name)
 
         self.model_info_row.set_title(model_name)
 
-        if backend == "whisper":
+        if backend == "moonshine":
+            if desc is None:
+                self.model_info_row.set_subtitle(_("Unknown model"))
+            else:
+                mtype = (desc.type or "").replace("_", " ").title()
+                size  = desc.size or _("unknown size")
+                quality = desc.quality or ""
+                if quality:
+                    self.model_info_row.set_subtitle(
+                        _("%s · %s · %s") % (mtype, quality, size))
+                else:
+                    self.model_info_row.set_subtitle(
+                        _("%s · %s") % (mtype, size))
+        elif backend == "whisper":
             if desc is None:
                 self.model_info_row.set_subtitle(_("Unknown model"))
             else:
@@ -307,7 +341,12 @@ class STTConfigDialog (Adw.Window):
         if getattr(self, '_suppress_engine_cb', False):
             return
 
-        backend = "vosk" if button == self.vosk_check else "whisper"
+        if button == self.vosk_check:
+            backend = "vosk"
+        elif button == self.moonshine_check:
+            backend = "moonshine"
+        else:
+            backend = "whisper"
         current = self._settings.get_string("backend")
         if backend == current:
             return
diff --git a/engine/sttconfigdialog.ui b/engine/sttconfigdialog.ui
index a874b97..089e0f1 100644
--- a/engine/sttconfigdialog.ui
+++ b/engine/sttconfigdialog.ui
@@ -70,6 +70,20 @@
                                         </child>
                                       </object>
                                     </child>
+                                    <child>
+                                      <object class="AdwActionRow" id="moonshine_action_row">
+                                        <property name="title">Moonshine</property>
+                                        <property name="subtitle" translatable="yes">Low-latency streaming, no voice commands</property>
+                                        <property name="activatable-widget">moonshine_check</property>
+                                        <child type="prefix">
+                                          <object class="GtkCheckButton" id="moonshine_check">
+                                            <property name="valign">center</property>
+                                            <property name="group">vosk_check</property>
+                                            <signal name="toggled" handler="engine_toggled_cb"/>
+                                          </object>
+                                        </child>
+                                      </object>
+                                    </child>
                                   </object>
                                 </child>
 
diff --git a/engine/sttgstfactory.py b/engine/sttgstfactory.py
index 00bcc47..d4c0aed 100644
--- a/engine/sttgstfactory.py
+++ b/engine/sttgstfactory.py
@@ -8,6 +8,7 @@ from sttutils import *
 
 from sttgstvosk import STTGstVosk
 from sttgstwhisper import STTGstWhisper
+from sttgstmoonshine import STTGstMoonshine
 
 LOG_MSG=logging.getLogger()
 
@@ -33,6 +34,9 @@ class STTGstFactory(GObject.GObject):
             if backend == "whisper":
                 LOG_MSG.info("Using Whisper backend")
                 engine=STTGstWhisper()
+            elif backend == "moonshine":
+                LOG_MSG.info("Using Moonshine backend")
+                engine=STTGstMoonshine()
             else:
                 LOG_MSG.info("Using Vosk backend")
                 engine=STTGstVosk()
diff --git a/engine/sttgstmoonshine.py b/engine/sttgstmoonshine.py
new file mode 100644
index 0000000..5722591
--- /dev/null
+++ b/engine/sttgstmoonshine.py
@@ -0,0 +1,303 @@
+# GStreamer recognition engine backed by Moonshine (moonshine_voice).
+#
+# Moonshine differs from the Vosk/Whisper backends in that it ships its own
+# streaming pipeline and voice-activity detection. We therefore do NOT run the
+# in-tree STTVad or window the audio ourselves: each chunk pulled from the
+# GStreamer appsink is converted to float32 and handed straight to a Moonshine
+# streaming Transcriber. Completed transcript lines are surfaced through the
+# usual "text" signal. Because Moonshine runs the model synchronously inside
+# add_audio()/stop(), all library calls happen on a dedicated worker thread so
+# the GStreamer streaming thread is never blocked; emitted text is marshalled
+# back onto the GLib main loop.
+
+import logging
+import threading
+import queue
+import numpy as np
+
+from gi.repository import Gst, GLib
+from sttutils import *
+from sttgstbase import STTGstBase
+from sttcurrentlocale import stt_current_locale
+from sttmoonshinemodel import STTMoonshineModel
+
+LOG_MSG = logging.getLogger()
+
+SAMPLE_RATE = 16000
+
+try:
+    from moonshine_voice import (
+        Transcriber,
+        TranscriptEventListener,
+        ModelArch,
+    )
+    MOONSHINE_AVAILABLE = True
+except ImportError:
+    LOG_MSG.warning("moonshine_voice not available. Install with: pip install moonshine-voice")
+    MOONSHINE_AVAILABLE = False
+    TranscriptEventListener = object
+
+
+class _LineListener(TranscriptEventListener):
+    """Bridges Moonshine transcript events back to the engine."""
+
+    def __init__(self, engine):
+        if MOONSHINE_AVAILABLE:
+            super().__init__()
+        self._engine = engine
+
+    def on_line_completed(self, event):
+        text = (event.line.text or "").strip()
+        if text:
+            LOG_MSG.info("Moonshine transcription result: '%s'", text)
+            GLib.idle_add(self._engine._emit_text, text)
+
+    def on_line_text_changed(self, event):
+        if not self._engine._use_partial_results:
+            return
+        text = (event.line.text or "").strip()
+        if text:
+            GLib.idle_add(self._engine._emit_text, text)
+
+
+class STTGstMoonshine(STTGstBase):
+    __gtype_name__ = 'STTGstMoonshine'
+    _pipeline_def = "pulsesrc blocksize=3200 buffer-time=9223372036854775807 ! " \
+                    "audio/x-raw,format=S16LE,rate=16000,channels=1 ! " \
+                    "webrtcdsp noise-suppression-level=3 echo-cancel=false ! " \
+                    "queue ! " \
+                    "appsink name=MoonshineSink emit-signals=true sync=false"
+
+    _pipeline_def_alt = "pulsesrc blocksize=3200 buffer-time=9223372036854775807 ! " \
+                        "audio/x-raw,format=S16LE,rate=16000,channels=1 ! " \
+                        "queue ! " \
+                        "appsink name=MoonshineSink emit-signals=true sync=false"
+
+    def __init__(self, current_locale=None):
+        plugin = Gst.Registry.get().find_plugin("webrtcdsp")
+        if plugin is not None:
+            super().__init__(pipeline_definition=STTGstMoonshine._pipeline_def)
+            LOG_MSG.debug("using Webrtcdsp plugin")
+        else:
+            super().__init__(pipeline_definition=STTGstMoonshine._pipeline_def_alt)
+            LOG_MSG.debug("not using Webrtcdsp plugin")
+
+        if self.pipeline is None:
+            LOG_MSG.error("pipeline was not created")
+            return
+
+        self._appsink = self.pipeline.get_by_name("MoonshineSink")
+        if self._appsink is None:
+            LOG_MSG.error("no appsink element!")
+            return
+
+        self._appsink.connect("new-sample", self._on_new_sample)
+
+        if current_locale is None:
+            self._current_locale = stt_current_locale()
+        else:
+            self._current_locale = current_locale
+
+        self._locale_id = self._current_locale.connect("changed", self._locale_changed)
+
+        self._model_id = 0
+        self._model = None
+        self._transcriber = None
+        self._listener = None
+        self._tx_lock = threading.Lock()
+        self._session_active = False
+
+        self._process_queue = queue.Queue()
+        self._process_thread = None
+        self._stop_processing = False
+        self._use_partial_results = False
+
+        self._set_model()
+
+    def __del__(self):
+        LOG_MSG.info("Moonshine __del__")
+        self._stop_processing = True
+        if self._process_thread is not None:
+            self._process_thread.join(timeout=2.0)
+        super().__del__()
+
+    def destroy(self):
+        self._stop_processing = True
+        if self._process_thread is not None:
+            self._process_thread.join(timeout=2.0)
+
+        self._current_locale.disconnect(self._locale_id)
+        self._locale_id = 0
+
+        if self._model_id != 0:
+            self._model.disconnect(self._model_id)
+            self._model_id = 0
+
+        with self._tx_lock:
+            self._teardown_transcriber()
+
+        self._appsink = None
+        LOG_MSG.info("Moonshine.destroy() called")
+        super().destroy()
+
+    # --- model loading ------------------------------------------------------
+
+    def _teardown_transcriber(self):
+        if self._transcriber is None:
+            return
+        try:
+            if self._session_active:
+                self._transcriber.stop()
+        except Exception as e:
+            LOG_MSG.debug("error stopping transcriber on teardown: %s", e)
+        self._session_active = False
+        self._transcriber = None
+        self._listener = None
+
+    def _load_moonshine_model(self, model_path, model_arch):
+        if not MOONSHINE_AVAILABLE:
+            LOG_MSG.error("moonshine_voice not available")
+            return False
+        try:
+            arch = model_arch if model_arch is not None else ModelArch.BASE
+            LOG_MSG.info("Loading Moonshine model: %s (arch=%s)", model_path, arch)
+            transcriber = Transcriber(model_path=model_path, model_arch=arch)
+            listener = _LineListener(self)
+            transcriber.add_listener(listener)
+            with self._tx_lock:
+                self._teardown_transcriber()
+                self._transcriber = transcriber
+                self._listener = listener
+            return True
+        except Exception as e:
+            LOG_MSG.error("Failed to load Moonshine model: %s", e)
+            with self._tx_lock:
+                self._teardown_transcriber()
+            return False
+
+    def _set_model_path(self):
+        if self._model is None or self._model.available() is False:
+            LOG_MSG.info("model path does not exist (%s - %s)",
+                         self._model.get_name() if self._model else "None",
+                         self._model.get_path() if self._model else "None")
+            with self._tx_lock:
+                self._teardown_transcriber()
+            self.emit("model-changed")
+            return
+
+        new_model_path = self._model.get_path()
+        new_model_arch = self._model.get_arch()
+        LOG_MSG.debug("model ready %s", new_model_path)
+
+        ret, state, pending = self.pipeline.get_state(0)
+        if state >= Gst.State.READY:
+            self.pipeline.set_state(Gst.State.READY)
+
+        success = self._load_moonshine_model(new_model_path, new_model_arch)
+
+        if state >= Gst.State.READY:
+            self.pipeline.set_state(state)
+
+        if success:
+            self.emit("model-changed")
+
+    def _model_changed(self, model):
+        self._set_model_path()
+
+    def _set_model(self):
+        if (self._model is not None and
+                self._model.get_locale() == self._current_locale.locale):
+            return
+
+        if self._model_id != 0:
+            self._model.disconnect(self._model_id)
+            self._model_id = 0
+
+        self._model = STTMoonshineModel(locale_str=self._current_locale.locale)
+        self._model_id = self._model.connect("changed", self._model_changed)
+        self._set_model_path()
+
+    def _locale_changed(self, locale):
+        self._set_model()
+
+    # --- audio capture ------------------------------------------------------
+
+    def _on_new_sample(self, appsink):
+        sample = appsink.emit("pull-sample")
+        if sample is None:
+            return Gst.FlowReturn.OK
+
+        buf = sample.get_buffer()
+        success, map_info = buf.map(Gst.MapFlags.READ)
+        if not success:
+            return Gst.FlowReturn.OK
+
+        audio_data = np.frombuffer(map_info.data, dtype=np.int16)
+        buf.unmap(map_info)
+
+        audio_float = audio_data.astype(np.float32) / 32768.0
+        self._process_queue.put(("audio", audio_float))
+
+        if self._process_thread is None or not self._process_thread.is_alive():
+            self._process_thread = threading.Thread(target=self._process_worker, daemon=True)
+            self._process_thread.start()
+
+        return Gst.FlowReturn.OK
+
+    def _process_worker(self):
+        """Feed queued audio into the Moonshine streaming transcriber."""
+        while not self._stop_processing:
+            try:
+                cmd, payload = self._process_queue.get(timeout=0.1)
+            except queue.Empty:
+                continue
+
+            try:
+                with self._tx_lock:
+                    transcriber = self._transcriber
+                    if transcriber is None:
+                        continue
+
+                    if cmd == "audio":
+                        if not self._session_active:
+                            transcriber.start()
+                            self._session_active = True
+                        transcriber.add_audio(payload, SAMPLE_RATE)
+                    elif cmd == "stop":
+                        if self._session_active:
+                            transcriber.stop()
+                            self._session_active = False
+            except Exception as e:
+                LOG_MSG.error("Moonshine processing error: %s", e, exc_info=True)
+            finally:
+                self._process_queue.task_done()
+
+    def _emit_text(self, text):
+        self.emit("text", text)
+        return False
+
+    # --- STTGstBase interface ----------------------------------------------
+
+    def get_final_results(self):
+        # Flush: drain queued audio, then end the session so Moonshine emits the
+        # final (completed) line, and re-arm for the next utterance.
+        self._process_queue.put(("stop", None))
+        self._process_queue.join()
+
+    def get_results(self):
+        pass
+
+    def set_use_partial_results(self, active):
+        self._use_partial_results = active
+
+    def set_alternatives_num(self, num):
+        pass
+
+    def has_model(self):
+        if self._model is None or self._model.available() is False:
+            return False
+        return super().has_model()
+
+    def _stop_real(self):
+        self.get_final_results()
+        return super()._stop_real()
diff --git a/engine/sttlocalerow.py b/engine/sttlocalerow.py
index bb5fb30..d662100 100644
--- a/engine/sttlocalerow.py
+++ b/engine/sttlocalerow.py
@@ -15,9 +15,11 @@ from sttutils import *
 
 from sttvoskmodel import STTVoskModel
 from sttwhispermodel import STTWhisperModel
+from sttmoonshinemodel import STTMoonshineModel
 from sttmodelchooserdialog import STTModelChooserDialog
 from sttvoskmodelmanagers import stt_vosk_online_model_manager
 from sttwhispermodelmanagers import stt_whisper_online_model_manager
+from sttmoonshinemodelmanagers import stt_moonshine_online_model_manager
 
 
 LOG_MSG=logging.getLogger()
@@ -59,7 +61,12 @@ class STTLocaleRow(Adw.ActionRow):
 
     def _init_model(self):
         backend = self._settings.get_string("backend")
-        self._model = STTWhisperModel(locale_str=self._locale) if backend == "whisper" else STTVoskModel(locale_str=self._locale)
+        if backend == "whisper":
+            self._model = STTWhisperModel(locale_str=self._locale)
+        elif backend == "moonshine":
+            self._model = STTMoonshineModel(locale_str=self._locale)
+        else:
+            self._model = STTVoskModel(locale_str=self._locale)
 
         self._model.connect("changed", self._model_changed)
         self.update_description()
@@ -117,8 +124,25 @@ class STTLocaleRow(Adw.ActionRow):
             return
 
         backend = self._settings.get_string("backend")
-        manager = stt_whisper_online_model_manager() if backend == "whisper" else stt_vosk_online_model_manager()
+        if backend == "whisper":
+            manager = stt_whisper_online_model_manager()
+        elif backend == "moonshine":
+            manager = stt_moonshine_online_model_manager()
+        else:
+            manager = stt_vosk_online_model_manager()
         model = manager.get_model_description(model_name)
+        if backend == "moonshine":
+            if model is None:
+                self.set_subtitle(_("Unknown Moonshine model"))
+            else:
+                model_type = (model.type or "").replace("_", " ").title()
+                size       = model.size or _("unknown size")
+                quality    = model.quality or ""
+                if quality:
+                    self.set_subtitle(_("%s – %s – %s") % (model_type, quality, size))
+                else:
+                    self.set_subtitle(_("%s – %s") % (model_type, size))
+            return
         if backend == "whisper":
             if model is None:
                 self.set_subtitle(_("Unknown Whisper model"))
diff --git a/engine/sttmodelchooserdialog.py b/engine/sttmodelchooserdialog.py
index 1b0a895..97dcd46 100644
--- a/engine/sttmodelchooserdialog.py
+++ b/engine/sttmodelchooserdialog.py
@@ -12,6 +12,8 @@ from sttmodelrow import STTModelRow
 from sttvoskmodelmanagers import stt_vosk_online_model_manager
 from sttwhispermodelmanagers import stt_whisper_online_model_manager
 from sttwhispermodel import STTWhisperModel
+from sttmoonshinemodelmanagers import stt_moonshine_online_model_manager
+from sttmoonshinemodel import STTMoonshineModel
 
 LOG_MSG=logging.getLogger()
 
@@ -41,13 +43,19 @@ class STTModelChooserDialog(Gtk.Dialog):
         self._model=model
 
         self._is_whisper = isinstance(model, STTWhisperModel)
-        self._manager = stt_whisper_online_model_manager() if self._is_whisper else stt_vosk_online_model_manager()
+        self._is_moonshine = isinstance(model, STTMoonshineModel)
+        if self._is_whisper:
+            self._manager = stt_whisper_online_model_manager()
+        elif self._is_moonshine:
+            self._manager = stt_moonshine_online_model_manager()
+        else:
+            self._manager = stt_vosk_online_model_manager()
 
         locale_str=model.get_locale()
         full_list=[]
 
         # For Whisper, use deduplication to avoid showing multilingual models twice
-        if self._is_whisper:
+        if self._is_whisper or self._is_moonshine:
             seen_models = set()
             models_to_check = [locale_str]
             if len(locale_str) > 2:
@@ -74,7 +82,12 @@ class STTModelChooserDialog(Gtk.Dialog):
         self._removed_id = self._manager.connect("removed", self._model_path_removed_cb)
 
         # Update dialog title based on backend
-        backend_name = "Whisper" if self._is_whisper else "Vosk"
+        if self._is_whisper:
+            backend_name = "Whisper"
+        elif self._is_moonshine:
+            backend_name = "Moonshine"
+        else:
+            backend_name = "Vosk"
         self.set_title(_("Manage %s Recognition Models") % backend_name)
 
     def _add_row(self, model_desc):
@@ -126,10 +139,13 @@ class STTModelChooserDialog(Gtk.Dialog):
     @Gtk.Template.Callback()
     def new_model_button_clicked_cb(self, button):
         root_widget=self.get_root()
-        # For Whisper, allow selecting files; for Vosk, allow selecting folders
+        # For Whisper, allow selecting files; for Vosk/Moonshine, allow selecting folders
         if self._is_whisper:
             action = Gtk.FileChooserAction.OPEN
             title = _("Open Whisper Model File")
+        elif self._is_moonshine:
+            action = Gtk.FileChooserAction.SELECT_FOLDER
+            title = _("Open Moonshine Model Folder")
         else:
             action = Gtk.FileChooserAction.SELECT_FOLDER
             title = _("Open Vosk Model Folder")
diff --git a/engine/sttmodelrow.py b/engine/sttmodelrow.py
index fc3fcf3..ec9ed4d 100644
--- a/engine/sttmodelrow.py
+++ b/engine/sttmodelrow.py
@@ -13,6 +13,7 @@ from sttutils import *
 from sttvoskmodelmanagers import STTDownloadState
 from sttwhispermodelmanagers import STTDownloadState as WhisperDownloadState
 from sttwhispermodelmanagers import STTDownloadState as WhisperDownloadState, STTWhisperModelDescription
+from sttmoonshinemodelmanagers import STTMoonshineModelDescription
 
 LOG_MSG=logging.getLogger()
 
@@ -160,6 +161,15 @@ class STTModelRow(Adw.ActionRow):
             lang = _("English only") if (self._desc.locale == "en") else _("Multilingual")
             description = _("%s \u2013 %s \u2013 %s") % (quality, lang, size)
 
+        elif isinstance(self._desc, STTMoonshineModelDescription):
+            quality = self._desc.quality or _("Streaming model")
+            mtype = (self._desc.type or "").replace("_", " ").title()
+            if self._desc.locale == "en":
+                lang = _("English only")
+            else:
+                lang = self._desc.locale.upper() if self._desc.locale else _("Multilingual")
+            description = _("%s \u2013 %s \u2013 %s") % (quality, lang, size)
+
         elif self._desc.type is not None:
             if self._desc.type.startswith("big") == True:
                 description=_("Large model that may be more accurate than smaller ones - %s") % size
diff --git a/engine/sttmoonshinemodel.py b/engine/sttmoonshinemodel.py
new file mode 100644
index 0000000..8e70381
--- /dev/null
+++ b/engine/sttmoonshinemodel.py
@@ -0,0 +1,155 @@
+# GObject wrapper tracking the Moonshine model selected for a given locale,
+# mirroring STTVoskModel / STTWhisperModel. The selection is persisted in the
+# "moonshine-models" gsettings key as a JSON object mapping a locale string to
+# either a catalogue model name (e.g. "base-en") or an absolute path to a
+# custom model folder.
+
+import json
+import logging
+
+from pathlib import Path
+from gi.repository import GObject, Gio
+
+from sttmoonshinemodelmanagers import (
+    stt_moonshine_local_model_manager,
+    MOONSHINE_AVAILABLE,
+)
+
+LOG_MSG = logging.getLogger()
+
+
+class STTMoonshineModel(GObject.Object):
+    __gtype_name__ = "STTMoonshineModel"
+    __gsignals__ = {
+        "changed": (GObject.SIGNAL_RUN_FIRST, None, ()),
+    }
+
+    def __init__(self, locale_str=None):
+        super().__init__()
+
+        self._locale_str = locale_str
+        self._settings = Gio.Settings.new("org.freedesktop.ibus.engine.stt")
+        self._settings_id = self._settings.connect("changed::moonshine-models", self._models_changed)
+
+        self._model_name = None
+        self._model_path = None
+        self._model_arch = None
+        self._valid_model = False
+
+        self._model_added_id = stt_moonshine_local_model_manager().connect("added", self._model_added_cb)
+        self._model_removed_id = stt_moonshine_local_model_manager().connect("removed", self._model_removed_cb)
+
+        model = self._get_model_from_settings()
+        self._set_model(model)
+
+    def __del__(self):
+        stt_moonshine_local_model_manager().disconnect(self._model_added_id)
+        stt_moonshine_local_model_manager().disconnect(self._model_removed_id)
+        if self._model_name is None and self._model_path is not None:
+            stt_moonshine_local_model_manager().unregister_custom_model_path(self._model_path)
+
+    def _get_model_from_settings(self):
+        models_json_string = self._settings.get_string("moonshine-models")
+        if models_json_string in (None, "None", ""):
+            return None
+        try:
+            models_dict = json.loads(models_json_string)
+        except json.JSONDecodeError:
+            return None
+        return models_dict.get(self._locale_str, None)
+
+    def _set_model(self, model):
+        LOG_MSG.debug("new moonshine model (%s, current path=%s / current name=%s)",
+                      model, self._model_path, self._model_name)
+        if model is None:
+            if self._model_name is None and self._model_path is None:
+                return
+            self._model_name = None
+            self._model_path = None
+            self._model_arch = None
+            self._valid_model = False
+            self.emit("changed")
+            return
+
+        model = model.rstrip("/")
+        local = stt_moonshine_local_model_manager()
+
+        if Path(model).is_absolute():
+            if self._model_name is None and self._model_path == model:
+                return
+            self._model_name = None
+            self._model_path = model
+            self._model_arch = local._infer_arch_for_folder(model) if MOONSHINE_AVAILABLE else None
+            local.register_custom_model_path(model, self._locale_str)
+            self._valid_model = local.custom_path_available(model)
+        else:
+            tmp_path = local.get_best_path_for_model(model)
+            if self._model_name == model and tmp_path == self._model_path:
+                return
+            self._model_name = model
+            self._model_path = tmp_path
+            self._model_arch = local.get_arch_for_model(model)
+            self._valid_model = bool(tmp_path is not None)
+
+        LOG_MSG.debug("moonshine model changed (valid=%s, path=%s, name=%s, arch=%s)",
+                      self._valid_model, self._model_path, self._model_name, self._model_arch)
+        self.emit("changed")
+
+    def _models_changed(self, settings, key):
+        self._set_model(self._get_model_from_settings())
+
+    def _model_added_cb(self, manager, name, path):
+        if self._model_name is not None:
+            if name != self._model_name:
+                return
+            self._model_path = path
+        elif self._model_path != path:
+            return
+        self._valid_model = True
+        self.emit("changed")
+
+    def _model_removed_cb(self, manager, name, path):
+        if self._model_name is not None:
+            if name != self._model_name:
+                return
+            self._model_path = manager.get_best_path_for_model(name)
+            self._valid_model = bool(self._model_path is not None)
+        elif self._model_path == path:
+            self._valid_model = False
+        else:
+            return
+        self.emit("changed")
+
+    def available(self):
+        return self._valid_model
+
+    def get_locale(self):
+        return self._locale_str
+
+    def get_name(self):
+        return self._model_name
+
+    def get_path(self):
+        return self._model_path
+
+    def get_arch(self):
+        return self._model_arch
+
+    def set_name(self, model_name):
+        self._set_model(model_name)
+
+        models_json_string = self._settings.get_string("moonshine-models")
+        if models_json_string in (None, "None", ""):
+            models_dict = {}
+        else:
+            try:
+                models_dict = json.loads(models_json_string)
+            except json.JSONDecodeError:
+                models_dict = {}
+
+        models_dict[self._locale_str] = model_name
+        models_json_string = json.dumps(models_dict)
+
+        self._settings.disconnect(self._settings_id)
+        self._settings.set_string("moonshine-models", models_json_string)
+        self._settings_id = self._settings.connect("changed::moonshine-models", self._models_changed)
diff --git a/engine/sttmoonshinemodelmanagers.py b/engine/sttmoonshinemodelmanagers.py
new file mode 100644
index 0000000..078dddb
--- /dev/null
+++ b/engine/sttmoonshinemodelmanagers.py
@@ -0,0 +1,378 @@
+# Moonshine model managers for ibus-speech-to-text.
+#
+# Unlike Vosk (a model is a folder the user points at) or Whisper (a model is
+# a single ggml .bin file), Moonshine ships a *family* of per-language model
+# folders and manages its own download cache. A "model" here is therefore one
+# concrete entry of moonshine_voice.download.MODEL_INFO, identified by its
+# globally-unique ``model_name`` (e.g. "base-en", "small-streaming-en",
+# "base-ar"). The cached model folder lives under Moonshine's own cache
+# (``$MOONSHINE_VOICE_CACHE`` or ~/.cache/moonshine_voice), so path resolution
+# is delegated to the moonshine_voice library rather than reimplemented.
+
+import os
+import logging
+import threading
+
+from pathlib import Path
+from enum import Enum
+
+from gi.repository import GObject, GLib
+
+LOG_MSG = logging.getLogger()
+
+try:
+    from moonshine_voice import ModelArch
+    from moonshine_voice.download import (
+        MODEL_INFO,
+        find_model_info,
+        get_components_for_model_info,
+        get_model_for_language,
+        supported_languages,
+    )
+    from moonshine_voice.download_file import get_cache_dir
+    MOONSHINE_AVAILABLE = True
+except ImportError:
+    LOG_MSG.warning("moonshine_voice not available. Install with: pip install moonshine-voice")
+    MOONSHINE_AVAILABLE = False
+    MODEL_INFO = {}
+    ModelArch = None
+
+
+# Rough on-disk sizes by architecture (quantized). Approximate, for display only.
+_ARCH_SIZES = {
+    "tiny":             "~50 MB",
+    "tiny-streaming":   "~70 MB",
+    "base":             "~120 MB",
+    "base-streaming":   "~120 MB",
+    "small-streaming":  "~260 MB",
+    "medium-streaming": "~520 MB",
+}
+
+# Short, human-readable quality blurb by architecture.
+_ARCH_QUALITY = {
+    "tiny":             "Fastest, lowest accuracy",
+    "tiny-streaming":   "Very fast streaming, low accuracy",
+    "base":             "Balanced",
+    "base-streaming":   "Balanced streaming",
+    "small-streaming":  "Good balance of speed and accuracy",
+    "medium-streaming": "Most accurate, slower and resource-heavy",
+}
+
+
+def _arch_to_string(model_arch):
+    # Mirror moonshine_voice.moonshine_api.model_arch_to_string without
+    # importing it (keeps this module importable when moonshine is absent).
+    return {
+        0: "tiny",
+        1: "base",
+        2: "tiny-streaming",
+        3: "base-streaming",
+        4: "small-streaming",
+        5: "medium-streaming",
+    }.get(int(model_arch), "base")
+
+
+class STTDownloadState(float, Enum):
+    STOPPED = -1.0
+    UNKNOWN_PROGRESS = -0.5
+    UNPACKING = -0.6
+    ONGOING = 0.0
+
+
+def _lang_of_locale(locale_str):
+    if not locale_str:
+        return None
+    return locale_str[0:2].lower()
+
+
+def _all_model_infos():
+    """Yield (model_name, lang, info_dict) for every Moonshine model."""
+    for lang, entry in MODEL_INFO.items():
+        for model in entry.get("models", []):
+            yield model["model_name"], lang, model
+
+
+def _expected_model_path(model_info):
+    """Folder where moonshine_voice caches this model (without downloading)."""
+    cache_dir = get_cache_dir()
+    folder = model_info["download_url"].replace("https://", "")
+    return Path(cache_dir, folder)
+
+
+def _model_present(model_info):
+    """True if all required component files for this model are on disk."""
+    root = _expected_model_path(model_info)
+    if not root.is_dir():
+        return False
+    try:
+        components = get_components_for_model_info(model_info)
+    except Exception:
+        components = ["tokenizer.bin"]
+    return all((root / component).is_file() for component in components)
+
+
+class STTMoonshineModelDescription(GObject.Object):
+    __gtype_name__ = "STTMoonshineModelDescription"
+
+    def __init__(self, init_model=None):
+        super().__init__()
+        self.name = init_model.name if init_model is not None else ""
+        self.custom = init_model.custom if init_model is not None else False
+        self.is_obsolete = False
+        self.paths = init_model.paths if init_model is not None else []
+        self.size = init_model.size if init_model is not None else ""
+        self.type = init_model.type if init_model is not None else ""
+        self.locale = init_model.locale if init_model is not None else ""
+        self.url = init_model.url if init_model is not None else ""
+        self.arch = init_model.arch if init_model is not None else None
+        self.lang = init_model.lang if init_model is not None else None
+        self.quality = init_model.quality if init_model is not None else ""
+
+        self._operation = None
+        self.download_progress = STTDownloadState.STOPPED
+
+    def _download_finished(self):
+        self._operation = None
+        self.download_progress = STTDownloadState.STOPPED
+        # Refresh on-disk path and notify the local manager.
+        info = find_model_info(self.lang, self.arch)
+        if _model_present(info):
+            path = str(_expected_model_path(info))
+            self.paths = [path]
+            stt_moonshine_local_model_manager()._notify_added(self.name, path, self.lang)
+        return False
+
+    def _download_thread(self, cancelled):
+        try:
+            # get_model_for_language downloads any missing component files
+            # (skipping ones already cached) and returns (folder, arch).
+            get_model_for_language(self.lang, self.arch)
+        except Exception as e:
+            LOG_MSG.error("Moonshine download failed (%s): %s", self.name, e)
+        if not cancelled.is_set():
+            GLib.idle_add(self._download_finished)
+        else:
+            self.download_progress = STTDownloadState.STOPPED
+
+    def start_downloading(self):
+        if self._operation is not None:
+            return
+        if not MOONSHINE_AVAILABLE:
+            LOG_MSG.error("cannot download, moonshine_voice not installed")
+            return
+
+        LOG_MSG.debug("start downloading moonshine model (%s)", self.name)
+        # Moonshine's downloader streams files itself; we can't easily expose a
+        # fraction, so present an indeterminate (pulsing) progress bar.
+        self.download_progress = STTDownloadState.UNKNOWN_PROGRESS
+        self._operation = threading.Event()
+        thread = threading.Thread(target=self._download_thread,
+                                  args=(self._operation,), daemon=True)
+        thread.start()
+
+    def stop_downloading(self):
+        # Component downloads are short and resume-safe; we only flag the
+        # in-flight operation as cancelled so the completion callback is a no-op.
+        if self._operation is not None:
+            self._operation.set()
+            self._operation = None
+        self.download_progress = STTDownloadState.STOPPED
+
+    def get_best_path_for_model(self):
+        if self.paths in [None, []]:
+            return None
+        return self.paths[0]
+
+    def delete_paths(self):
+        if self.custom is True:
+            return
+        for path in list(self.paths):
+            root = Path(path)
+            try:
+                if root.is_dir():
+                    for child in root.iterdir():
+                        if child.is_file():
+                            child.unlink()
+            except Exception as e:
+                LOG_MSG.error("Failed to delete %s: %s", path, e)
+        self._operation = None
+        self.download_progress = STTDownloadState.STOPPED
+        old_paths = self.paths
+        self.paths = []
+        for path in old_paths:
+            stt_moonshine_local_model_manager()._notify_removed(self.name, path)
+
+
+class STTMoonshineLocalModelManager(GObject.Object):
+    __gtype_name__ = "STTMoonshineLocalModelManager"
+
+    __gsignals__ = {
+        "added": (GObject.SIGNAL_RUN_FIRST, None, (str, str,)),
+        "removed": (GObject.SIGNAL_RUN_FIRST, None, (str, str,)),
+    }
+
+    def __init__(self):
+        super().__init__()
+        self._present = {}        # model_name -> path
+        self._custom_paths = {}   # path -> locale_str
+        self._scan_present_models()
+
+    def _scan_present_models(self):
+        if not MOONSHINE_AVAILABLE:
+            return
+        for model_name, lang, info in _all_model_infos():
+            info = dict(info, language=lang)
+            if _model_present(info):
+                self._present[model_name] = str(_expected_model_path(info))
+                LOG_MSG.debug("moonshine model present on disk (%s)", model_name)
+
+    def _notify_added(self, model_name, path, lang=None):
+        self._present[model_name] = path
+        self.emit("added", model_name, path)
+
+    def _notify_removed(self, model_name, path):
+        self._present.pop(model_name, None)
+        self.emit("removed", model_name, path)
+
+    def path_available(self, model_path):
+        return model_path in self._present.values() or model_path in self._custom_paths
+
+    def get_best_path_for_model(self, model_name):
+        if model_name is None:
+            return None
+        return self._present.get(model_name, None)
+
+    def get_arch_for_model(self, model_name):
+        if not MOONSHINE_AVAILABLE:
+            return None
+        for name, lang, info in _all_model_infos():
+            if name == model_name:
+                return info["model_arch"]
+        return None
+
+    def get_lang_for_model(self, model_name):
+        if not MOONSHINE_AVAILABLE:
+            return None
+        for name, lang, info in _all_model_infos():
+            if name == model_name:
+                return lang
+        return None
+
+    # --- custom (user-picked folder) support -------------------------------
+
+    @staticmethod
+    def _infer_arch_for_folder(model_path):
+        root = Path(model_path)
+        if (root / "streaming_config.json").is_file():
+            # Streaming family; size is ambiguous from files alone. Bias the
+            # guess from the folder name when possible, else small-streaming.
+            name = root.name.lower()
+            for token, arch in (("medium", ModelArch.MEDIUM_STREAMING),
+                                ("small", ModelArch.SMALL_STREAMING),
+                                ("base", ModelArch.BASE_STREAMING),
+                                ("tiny", ModelArch.TINY_STREAMING)):
+                if token in name:
+                    return arch
+            return ModelArch.SMALL_STREAMING
+        if "tiny" in root.name.lower():
+            return ModelArch.TINY
+        return ModelArch.BASE
+
+    def register_custom_model_path(self, model_path, locale_str):
+        self._custom_paths[model_path] = locale_str
+
+    def unregister_custom_model_path(self, model_path):
+        self._custom_paths.pop(model_path, None)
+
+    def custom_path_available(self, model_path):
+        return Path(model_path).is_dir() and (Path(model_path) / "tokenizer.bin").is_file()
+
+
+_GLOBAL_LOCAL_MANAGER = None
+
+
+def stt_moonshine_local_model_manager():
+    global _GLOBAL_LOCAL_MANAGER
+    if _GLOBAL_LOCAL_MANAGER is None:
+        _GLOBAL_LOCAL_MANAGER = STTMoonshineLocalModelManager()
+    return _GLOBAL_LOCAL_MANAGER
+
+
+class STTMoonshineOnlineModelManager(GObject.Object):
+    __gtype_name__ = "STTMoonshineOnlineModelManager"
+    __gsignals__ = {
+        "added": (GObject.SIGNAL_RUN_FIRST, None, (object,)),
+        "changed": (GObject.SIGNAL_RUN_FIRST, None, (object,)),
+        "removed": (GObject.SIGNAL_RUN_FIRST, None, (object,)),
+    }
+
+    def __init__(self):
+        super().__init__()
+        self._models = {}          # model_name -> STTMoonshineModelDescription
+        self._locales_dict = {}    # lang -> [descriptions]
+        self._build_catalog()
+
+        local = stt_moonshine_local_model_manager()
+        local.connect("added", self._model_path_added_cb)
+        local.connect("removed", self._model_path_removed_cb)
+
+    def _build_catalog(self):
+        if not MOONSHINE_AVAILABLE:
+            return
+        for model_name, lang, info in _all_model_infos():
+            arch = info["model_arch"]
+            arch_str = _arch_to_string(arch)
+
+            desc = STTMoonshineModelDescription()
+            desc.name = model_name
+            desc.lang = lang
+            desc.locale = lang
+            desc.arch = arch
+            desc.type = arch_str
+            desc.url = info["download_url"]
+            desc.size = _ARCH_SIZES.get(arch_str, "")
+            desc.quality = _ARCH_QUALITY.get(arch_str, "")
+
+            path = stt_moonshine_local_model_manager().get_best_path_for_model(model_name)
+            if path is not None:
+                desc.paths = [path]
+
+            self._models[model_name] = desc
+            self._locales_dict.setdefault(lang, []).append(desc)
+
+    def _model_path_added_cb(self, manager, model_name, model_path):
+        desc = self._models.get(model_name, None)
+        if desc is None:
+            return
+        if model_path not in desc.paths:
+            desc.paths = [model_path]
+        self.emit("changed", desc)
+
+    def _model_path_removed_cb(self, manager, model_name, model_path):
+        desc = self._models.get(model_name, None)
+        if desc is None:
+            return
+        desc.paths = []
+        self.emit("changed", desc)
+
+    def get_model_description(self, model_name):
+        return self._models.get(model_name, None)
+
+    def get_models_for_locale(self, locale_str):
+        lang = _lang_of_locale(locale_str)
+        return list(self._locales_dict.get(lang, []))
+
+    def supported_locales(self):
+        if not MOONSHINE_AVAILABLE:
+            return []
+        return list(self._locales_dict.keys())
+
+
+_GLOBAL_ONLINE_MANAGER = None
+
+
+def stt_moonshine_online_model_manager():
+    global _GLOBAL_ONLINE_MANAGER
+    if _GLOBAL_ONLINE_MANAGER is None:
+        _GLOBAL_ONLINE_MANAGER = STTMoonshineOnlineModelManager()
+    return _GLOBAL_ONLINE_MANAGER
diff --git a/engine/meson.build b/engine/meson.build
--- a/engine/meson.build
+++ b/engine/meson.build
@@ -4,6 +4,7 @@ stt_sources = [
     'sttgstvosk.py',
     'sttgstwhisper.py',
+    'sttgstmoonshine.py',
     'sttgstfactory.py',
     'sttgstbase.py',
     'sttsegmentprocess.py',
@@ -11,6 +12,7 @@ stt_sources = [
     'sttlocalerow.py',
     'sttvoskmodel.py',
     'sttwhispermodel.py',
+    'sttmoonshinemodel.py',
     'sttcurrentlocale.py',
     'sttutterancetree.py',
     'sttshortcutrow.py',
@@ -20,6 +22,7 @@ stt_sources = [
     'sttmodelchooserdialog.py',
     'sttvoskmodelmanagers.py',
     'sttwhispermodelmanagers.py',
+    'sttmoonshinemodelmanagers.py',
     'sttwordstodigits.py',
     'sttmodelrow.py'
     ]
diff --git a/data/org.freedesktop.ibus.engine.stt.gschema.xml.in b/data/org.freedesktop.ibus.engine.stt.gschema.xml.in
--- a/data/org.freedesktop.ibus.engine.stt.gschema.xml.in
+++ b/data/org.freedesktop.ibus.engine.stt.gschema.xml.in
@@ -51,5 +51,10 @@
       <default>'None'</default>
       <description>A JSON formatted string that is used to associate locales with their Whisper models. It can be the name of a model if it is in default monitored paths or a custom path.</description>
     </key>
+    <key type="s" name="moonshine-models">
+      <summary>Names or paths of Moonshine models</summary>
+      <default>'None'</default>
+      <description>A JSON formatted string that associates locales with their Moonshine models. Each value is a Moonshine model name (for example 'base-en' or 'small-streaming-en') resolved from the Moonshine cache, or an absolute path to a custom model folder.</description>
+    </key>
   </schema>
 </schemalist>


















def _load_moonshine_model(self, model_path, model_arch):
        """Load Moonshine model using moonshine-voice library."""
        if not MOONSHINE_AVAILABLE:
            LOG_MSG.error("moonshine-voice not available")
            return False

        try:
            from moonshine_voice.moonshine_api import ModelArch

            LOG_MSG.info(
                "Loading Moonshine model: path=%s, arch=%s", model_path, model_arch
            )

            # Stop any existing transcriber
            self._stop_transcriber()

            # Convert int arch to ModelArch enum
            if isinstance(model_arch, int):
                model_arch_enum = ModelArch(model_arch)
            else:
                model_arch_enum = model_arch

            # Determine options based on locale
            options = {}
            lang_code = None
            if self._current_locale and self._current_locale.locale:
                lang_code = self._current_locale.locale[:2]

            if lang_code and lang_code in ('ar', 'ja', 'ko', 'zh', 'uk', 'vi'):
                options['max_tokens_per_second'] = '13.0'

            self._transcriber = Transcriber(
                model_path=model_path,
                model_arch=model_arch_enum,
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








IBus-Speech-To-Text/builddir$ /usr/libexec/ibus-engine-stt 
INFO: 	main.py:49:__init__: 	Init
INFO: 	main.py:60:do_handle_local_options: 	Local options parsing
INFO: 	main.py:84:do_startup: 	startup
INFO: 	main.py:91:do_command_line: 	Remote options parsing False
INFO: 	main.py:117:do_activate: 	activated (False/('en_US', 'UTF-8'))
INFO: 	sttgstfactory.py:56:new_engine: 	Using Moonshine backend
INFO: 	sttgstmoonshine.py:150:_load_moonshine_model: 	Loading Moonshine model: path=/home/matiwari/.cache/moonshine_voice/download.moonshine.ai/model/tiny-streaming-en/quantized, arch=2
ERROR: 	sttgstmoonshine.py:182:_load_moonshine_model: 	Failed to load Moonshine model: 'int' object has no attribute 'value'
INFO: 	sttgstfactory.py:76:__update_preloaded_engine: 	preloading engine




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





  
