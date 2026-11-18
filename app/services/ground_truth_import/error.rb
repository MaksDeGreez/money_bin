module GroundTruthImport
  # Why the ground-truth import could not run at all (the folder is missing, an unexpected error). The
  # message is built by the import itself, never from a file's content, so it can be printed.
  class Error < StandardError; end
end
