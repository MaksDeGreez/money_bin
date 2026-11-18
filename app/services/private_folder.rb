# Checks for folders that hold personal data (saved receipt files, exported ground truth): they must stay
# outside every git repository, as the Python tools require of their output folders.
module PrivateFolder
  module_function

  # Whether `path` (which may not exist yet) is inside a git working tree. `.git` is a folder in a normal
  # checkout and a file in a linked worktree. Symbolic links are resolved first (through the deepest folder
  # that exists), so a link from outside into a checkout is seen for what it is.
  def inside_git_repository?(path)
    expanded = Pathname(File.expand_path(path))
    existing = expanded.ascend.find(&:exist?)
    resolved = existing.realpath.join(expanded.relative_path_from(existing))
    resolved.ascend.any? { |folder| folder.join(".git").exist? }
  end
end
