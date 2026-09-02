from __future__ import annotations

import threading
from ctypes import (POINTER, Structure, Union, byref, c_byte, c_int, c_longlong,
                    c_uint32, c_ulonglong, c_ushort, c_void_p, cast, sizeof,
                    string_at, windll)
from ctypes.wintypes import BOOL, DWORD, HANDLE, LPCWSTR, WORD

from musicui import config

try:
    from ctypes import HRESULT

    import comtypes
    import numpy as np
    from comtypes import COMMETHOD, COMObject, GUID, IUnknown

    AVAILABLE = True
    IMPORT_ERROR = None
except Exception as exc:                                # pragma: no cover
    AVAILABLE = False
    IMPORT_ERROR = f"{type(exc).__name__}: {exc}"

VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK = "VAD\\Process_Loopback"

AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK = 1
PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE = 0

AUDCLNT_SHAREMODE_SHARED = 0
AUDCLNT_STREAMFLAGS_LOOPBACK = 0x00020000
AUDCLNT_STREAMFLAGS_EVENTCALLBACK = 0x00040000
AUDCLNT_BUFFERFLAGS_SILENT = 0x2

WAVE_FORMAT_PCM = 1
REFTIMES_PER_20MS = 200_000
WAIT_TIMEOUT = 0x102
VT_BLOB = 65

if AVAILABLE:
    IID_IAudioClient = GUID("{1CB9AD4C-DBFA-4C32-B178-C2F568A703B2}")
    IID_IAudioCaptureClient = GUID("{C8ADBD64-E71E-48A0-A4DE-185C395CD317}")

    class WAVEFORMATEX(Structure):
        _fields_ = [
            ("wFormatTag", WORD),
            ("nChannels", WORD),
            ("nSamplesPerSec", DWORD),
            ("nAvgBytesPerSec", DWORD),
            ("nBlockAlign", WORD),
            ("wBitsPerSample", WORD),
            ("cbSize", WORD),
        ]

    class AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS(Structure):
        _fields_ = [
            ("TargetProcessId", DWORD),
            ("ProcessLoopbackMode", c_int),
        ]

    class _ActivationUnion(Union):
        _fields_ = [("ProcessLoopbackParams", AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS)]

    class AUDIOCLIENT_ACTIVATION_PARAMS(Structure):
        _fields_ = [
            ("ActivationType", c_int),
            ("Params", _ActivationUnion),
        ]

    class _BLOB(Structure):
        _fields_ = [("cbSize", DWORD), ("pBlobData", POINTER(c_byte))]

    class _PropVariantUnion(Union):
        _fields_ = [("blob", _BLOB), ("padding", c_byte * 16)]

    class PROPVARIANT(Structure):
        _fields_ = [
            ("vt", c_ushort),
            ("wReserved1", c_ushort),
            ("wReserved2", c_ushort),
            ("wReserved3", c_ushort),
            ("value", _PropVariantUnion),
        ]

    class IAudioClient(IUnknown):
        _iid_ = IID_IAudioClient
        _methods_ = (
            COMMETHOD([], HRESULT, "Initialize",
                      (["in"], c_uint32, "ShareMode"),
                      (["in"], DWORD, "StreamFlags"),
                      (["in"], c_longlong, "hnsBufferDuration"),
                      (["in"], c_longlong, "hnsPeriodicity"),
                      (["in"], POINTER(WAVEFORMATEX), "pFormat"),
                      (["in"], POINTER(GUID), "AudioSessionGuid")),
            COMMETHOD([], HRESULT, "GetBufferSize",
                      (["out"], POINTER(c_uint32), "pNumBufferFrames")),
            COMMETHOD([], HRESULT, "GetStreamLatency",
                      (["out"], POINTER(c_longlong), "phnsLatency")),
            COMMETHOD([], HRESULT, "GetCurrentPadding",
                      (["out"], POINTER(c_uint32), "pNumPaddingFrames")),
            COMMETHOD([], HRESULT, "IsFormatSupported",
                      (["in"], c_uint32, "ShareMode"),
                      (["in"], POINTER(WAVEFORMATEX), "pFormat"),
                      (["out"], POINTER(POINTER(WAVEFORMATEX)), "ppClosestMatch")),
            COMMETHOD([], HRESULT, "GetMixFormat",
                      (["out"], POINTER(POINTER(WAVEFORMATEX)), "ppDeviceFormat")),
            COMMETHOD([], HRESULT, "GetDevicePeriod",
                      (["out"], POINTER(c_longlong), "phnsDefaultDevicePeriod"),
                      (["out"], POINTER(c_longlong), "phnsMinimumDevicePeriod")),
            COMMETHOD([], HRESULT, "Start"),
            COMMETHOD([], HRESULT, "Stop"),
            COMMETHOD([], HRESULT, "Reset"),
            COMMETHOD([], HRESULT, "SetEventHandle",
                      (["in"], HANDLE, "eventHandle")),
            COMMETHOD([], HRESULT, "GetService",
                      (["in"], POINTER(GUID), "riid"),
                      (["out"], POINTER(POINTER(IUnknown)), "ppv")),
        )

    class IAudioCaptureClient(IUnknown):
        _iid_ = IID_IAudioCaptureClient
        _methods_ = (
            COMMETHOD([], HRESULT, "GetBuffer",
                      (["out"], POINTER(POINTER(c_byte)), "ppData"),
                      (["out"], POINTER(c_uint32), "pNumFramesToRead"),
                      (["out"], POINTER(DWORD), "pdwFlags"),
                      (["out"], POINTER(c_ulonglong), "pu64DevicePosition"),
                      (["out"], POINTER(c_ulonglong), "pu64QPCPosition")),
            COMMETHOD([], HRESULT, "ReleaseBuffer",
                      (["in"], c_uint32, "NumFramesRead")),
            COMMETHOD([], HRESULT, "GetNextPacketSize",
                      (["out"], POINTER(c_uint32), "pNumFramesInNextPacket")),
        )

    class IActivateAudioInterfaceAsyncOperation(IUnknown):
        _iid_ = GUID("{72A22D78-CDE4-431D-B8CC-843A71199B6D}")
        _methods_ = (
            COMMETHOD([], HRESULT, "GetActivateResult",
                      (["out"], POINTER(c_int), "activateResult"),
                      (["out"], POINTER(POINTER(IUnknown)), "activatedInterface")),
        )

    class IActivateAudioInterfaceCompletionHandler(IUnknown):
        _iid_ = GUID("{41D949AB-9862-444A-80F6-C261334DA5EB}")
        _methods_ = (
            COMMETHOD([], HRESULT, "ActivateCompleted",
                      (["in"], POINTER(IActivateAudioInterfaceAsyncOperation),
                       "activateOperation")),
        )

    class IAgileObject(IUnknown):
        _iid_ = GUID("{94EA2B94-E9CC-49E0-C0FF-EE64CA8F5B90}")
        _methods_ = ()

    class _CompletionHandler(COMObject):
        _com_interfaces_ = [IActivateAudioInterfaceCompletionHandler, IAgileObject]

        def __init__(self):
            super().__init__()
            self.done = threading.Event()

        def ActivateCompleted(self, *_args):
            self.done.set()
            return 0

    _kernel32 = windll.kernel32
    _kernel32.CreateEventW.argtypes = [c_void_p, BOOL, BOOL, LPCWSTR]
    _kernel32.CreateEventW.restype = HANDLE
    _kernel32.WaitForSingleObject.argtypes = [HANDLE, DWORD]
    _kernel32.WaitForSingleObject.restype = DWORD
    _kernel32.CloseHandle.argtypes = [HANDLE]
    _kernel32.CloseHandle.restype = BOOL

    _mmdevapi = windll.LoadLibrary("Mmdevapi.dll")
    _ActivateAudioInterfaceAsync = _mmdevapi.ActivateAudioInterfaceAsync
    _ActivateAudioInterfaceAsync.argtypes = [
        LPCWSTR,
        POINTER(GUID),
        POINTER(PROPVARIANT),
        POINTER(IActivateAudioInterfaceCompletionHandler),
        POINTER(POINTER(IActivateAudioInterfaceAsyncOperation)),
    ]
    _ActivateAudioInterfaceAsync.restype = HRESULT


def _activate_client(pid: int, keep: list, timeout: float = 3.0):
    params = AUDIOCLIENT_ACTIVATION_PARAMS()
    params.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK
    params.Params.ProcessLoopbackParams.TargetProcessId = int(pid)
    params.Params.ProcessLoopbackParams.ProcessLoopbackMode = (
        PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE
    )

    prop = PROPVARIANT()
    prop.vt = VT_BLOB
    prop.value.blob.cbSize = sizeof(params)
    prop.value.blob.pBlobData = cast(byref(params), POINTER(c_byte))

    handler = _CompletionHandler()
    handler_ptr = handler.QueryInterface(IActivateAudioInterfaceCompletionHandler)
    operation = POINTER(IActivateAudioInterfaceAsyncOperation)()
    keep.append((handler, handler_ptr, operation))

    _ActivateAudioInterfaceAsync(
        VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK,
        byref(IID_IAudioClient),
        byref(prop),
        handler_ptr,
        byref(operation),
    )

    if not handler.done.wait(timeout):
        raise TimeoutError("ActivateAudioInterfaceAsync не ответил")

    hr, unknown = operation.GetActivateResult()
    if hr != 0 or not unknown:
        raise OSError(f"GetActivateResult hr=0x{hr & 0xFFFFFFFF:08X}")

    return unknown.QueryInterface(IAudioClient)


class ProcessLoopbackCapture(threading.Thread):
    def __init__(self, pid: int, on_frames, samplerate: int = config.SAMPLE_RATE,
                 channels: int = 2):
        super().__init__(name=f"di-proc-loopback-{pid}", daemon=True)
        self.pid = int(pid)
        self.on_frames = on_frames
        self.samplerate = samplerate
        self.channels = channels
        self.ok = False
        self.error = None if AVAILABLE else IMPORT_ERROR
        self.started_event = threading.Event()
        self._stop = threading.Event()
        self._keep = []

    def stop(self):
        self._stop.set()

    def run(self):
        if not AVAILABLE:
            self.started_event.set()
            return

        comtypes.CoInitializeEx(comtypes.COINIT_MULTITHREADED)
        client = capture = None
        event = None
        try:
            client = _activate_client(self.pid, self._keep)

            fmt = WAVEFORMATEX(
                wFormatTag=WAVE_FORMAT_PCM,
                nChannels=self.channels,
                nSamplesPerSec=self.samplerate,
                nAvgBytesPerSec=self.samplerate * self.channels * 2,
                nBlockAlign=self.channels * 2,
                wBitsPerSample=16,
                cbSize=0,
            )
            client.Initialize(
                AUDCLNT_SHAREMODE_SHARED,
                AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
                REFTIMES_PER_20MS,
                0,
                byref(fmt),
                None,
            )

            event = _kernel32.CreateEventW(None, False, False, None)
            if not event:
                raise OSError("CreateEventW вернул NULL")
            client.SetEventHandle(event)

            capture = client.GetService(byref(IID_IAudioCaptureClient)) \
                            .QueryInterface(IAudioCaptureClient)
            client.Start()

            self.ok = True
            self.started_event.set()

            while not self._stop.is_set():
                if _kernel32.WaitForSingleObject(event, 200) == WAIT_TIMEOUT:
                    continue
                self._drain(capture)

        except Exception as exc:
            self.error = f"{type(exc).__name__}: {exc}"
        finally:
            self.ok = False
            self.started_event.set()
            try:
                if client is not None:
                    client.Stop()
            except Exception:
                pass
            capture = None
            client = None
            if event:
                _kernel32.CloseHandle(event)
            comtypes.CoUninitialize()

    def _drain(self, capture):
        while not self._stop.is_set():
            try:
                pending = capture.GetNextPacketSize()
            except Exception:
                return
            if not pending:
                return

            data, frames, flags, _dev_pos, _qpc = capture.GetBuffer()
            try:
                if frames:
                    if flags & AUDCLNT_BUFFERFLAGS_SILENT:
                        mono = np.zeros(frames, dtype=np.float32)
                    else:
                        raw = string_at(cast(data, c_void_p), frames * self.channels * 2)
                        pcm = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
                        mono = (pcm.reshape(-1, self.channels).mean(axis=1)
                                if self.channels > 1 else pcm)
                    self.on_frames(mono)
            finally:
                capture.ReleaseBuffer(frames)
