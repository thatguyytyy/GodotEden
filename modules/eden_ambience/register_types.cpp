#include "register_types.h"
#include "eden_ambience.h"
#include "eden_ambience_audio.h"
#include "eden_weather_server.h"

void initialize_eden_ambience_module(ModuleInitializationLevel p_level) {
	if (p_level == MODULE_INITIALIZATION_LEVEL_SCENE) {
		GDREGISTER_CLASS(AudioStreamEdenAmbience);
		GDREGISTER_CLASS(AudioStreamPlaybackEdenAmbience);
		GDREGISTER_CLASS(EdenAmbience);
		GDREGISTER_CLASS(EdenWeatherServer);
	}
}

void uninitialize_eden_ambience_module(ModuleInitializationLevel p_level) {
}
