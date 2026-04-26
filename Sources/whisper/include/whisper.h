#pragma once

/*
 This lightweight header keeps the SwiftPM system-library target importable
 before the real whisper.cpp artifact has been built into
 Vendor/whisper-artifacts/current. The runtime avoids calling C symbols unless
 a real artifact is present.
 */
const char * whisper_print_system_info(void);
