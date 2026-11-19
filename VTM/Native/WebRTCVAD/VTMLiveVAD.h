#ifndef VTM_LIVE_VAD_H_
#define VTM_LIVE_VAD_H_

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Each context belongs to one serialized audio producer. 16 kHz mono PCM16 only. */
void *VTMLiveVADCreate(void);
/* Frame length: 160, 320 or 480 samples. 1 = voice, 0 = non-voice, -1 = invalid. */
int VTMLiveVADProcess(void *context, const int16_t *samples, size_t length);
void VTMLiveVADFree(void *context);

#ifdef __cplusplus
}
#endif
#endif
