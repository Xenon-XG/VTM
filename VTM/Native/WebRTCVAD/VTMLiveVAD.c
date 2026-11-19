#include "VTMLiveVAD.h"
#include "webrtc/common_audio/vad/include/webrtc_vad.h"

void *VTMLiveVADCreate(void) {
    VadInst *instance = WebRtcVad_Create();
    if (instance == NULL) {
        return NULL;
    }
    if (WebRtcVad_Init(instance) != 0 || WebRtcVad_set_mode(instance, 2) != 0) {
        WebRtcVad_Free(instance);
        return NULL;
    }
    return instance;
}

int VTMLiveVADProcess(void *context, const int16_t *samples, size_t length) {
    if (context == NULL || samples == NULL ||
        (length != 160 && length != 320 && length != 480)) {
        return -1;
    }
    return WebRtcVad_Process((VadInst *)context, 16000, samples, length);
}

void VTMLiveVADFree(void *context) {
    if (context != NULL) {
        WebRtcVad_Free((VadInst *)context);
    }
}
