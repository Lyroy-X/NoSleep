# Design

The existing sleep and display controls use process-owned IOKit idle assertions. Their dependency and timers continue to operate together. The separate lid switch uses the already authorized `pmset -a disablesleep 1/0` commands and confirms the result through `SleepDisabled`. It uses the same power queue. The system-wide override suppresses sleep with an open lid as well, which the UI states explicitly. Apple's [lid policy](https://github.com/apple-oss-distributions/xnu/blob/main/iokit/Kernel/IOPMrootDomain.cpp#L4127-L4137) can keep a closed Mac awake in desktop mode.

Record ownership of the global override before setting it. An existing externally imposed override stays untouched. On quit, clear only the NoSleep override and retain the saved selection. At the first launch after update, migrate the previous saved system selection into the new preference. Fresh profiles start with the lid switch off.

Release 4.2.0 carries forward the local 4.1.1 watchdog fix. The power queue records missing protection in diagnostics and publishes confirmed UI state after the repair attempt. Independent command and watchdog errors remain visible on their corresponding controls.
