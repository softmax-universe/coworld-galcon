import
  polyworld/replaylibraries as sharedLibraries,
  polyworld/tapes,
  replays

export sharedLibraries.ReplayEntry

proc replayTicks(bytes: string): int =
  ## Validates Galcon's complete payload before marking a file playable.
  decodeRecording(bytes).hashes.len

const Library* = ReplayLibrary(
  gameFolder: "Galcon",
  gamePrefix: "Galcon",
  format: ReplayLibraryFormat(
    game: "galcon",
    gameVersion: ReplayVersion,
    maxBytes: DefaultMaxReplayBytes,
    payloadHeader: OpaquePayloadHeader
  ),
  inspect: replayTicks
)

proc replayDirectory*(): string =
  ## Returns Galcon's replay folder in the current user's application data.
  sharedLibraries.replayDirectory(Library)

proc ensureReplayDirectory*(directory = replayDirectory()): string =
  ## Creates and returns the library without relying on the game directory.
  sharedLibraries.ensureReplayDirectory(Library, directory)

proc inspectReplay*(path: string): ReplayEntry =
  ## Describes a valid, incompatible, or unreadable Galcon recording.
  sharedLibraries.inspectReplay(Library, path)

proc listReplays*(directory = replayDirectory()): seq[ReplayEntry] =
  ## Lists Galcon's recordings with newest files first.
  sharedLibraries.listReplays(Library, directory)

proc saveLibraryReplay*(
  recording: Recording, directory = replayDirectory()
): string =
  ## Validates and saves the complete match under a unique library filename.
  sharedLibraries.saveLibraryReplay(
    Library, recording.encodeRecording(), directory
  )

proc importReplay*(source: string, directory = replayDirectory()): string =
  ## Copies a recording while preserving unsupported versions and the source.
  sharedLibraries.importReplay(Library, source, directory)
