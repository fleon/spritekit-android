// The service protocols (audio, achievements, billing, the cloud and the
// merge saved data rides on) live in PlatformServices, which Apple builds
// share; the Android backends here adopt them, and everything that imports
// PlatformShim still sees them.
@_exported import PlatformServices
