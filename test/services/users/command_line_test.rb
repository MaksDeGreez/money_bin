require "test_helper"
require "rake"

module Users
  class CommandLineTest < ActiveSupport::TestCase
    PASSWORD = "a-long-enough-password"

    setup { @output = StringIO.new }

    def command_line(env: {}, input: "")
      CommandLine.new(env:, input: StringIO.new(input), output: @output)
    end

    test "creates the user from the terminal and never prints the password" do
      User.delete_all

      user = command_line(input: "First@Example.com\n#{PASSWORD}\n#{PASSWORD}\n").create_user

      assert_equal "first@example.com", user.email_address
      assert user.authenticate(PASSWORD)
      assert_includes @output.string, "Created the user first@example.com."
      assert_not_includes @output.string, PASSWORD
    end

    test "creates the user from environment variables without asking" do
      User.delete_all
      env = { "MONEY_BIN_EMAIL" => "script@example.com", "MONEY_BIN_PASSWORD" => PASSWORD }

      user = command_line(env:).create_user

      assert user.authenticate(PASSWORD)
      assert_not_includes @output.string, "Password"
    end

    test "refuses a second user" do
      error = assert_raises(CommandLine::Error) { command_line(input: "x@example.com\n").create_user }

      assert_match(/already a user \(owner@example\.com\)/, error.message)
      assert_equal 1, User.count
    end

    test "refuses two different passwords" do
      User.delete_all

      error = assert_raises(CommandLine::Error) do
        command_line(input: "first@example.com\n#{PASSWORD}\nanother-long-password\n").create_user
      end

      assert_equal "The passwords do not match.", error.message
      assert_not User.exists?
    end

    test "refuses a short password with the model's message" do
      User.delete_all
      env = { "MONEY_BIN_EMAIL" => "first@example.com", "MONEY_BIN_PASSWORD" => "short" }

      error = assert_raises(CommandLine::Error) { command_line(env:).create_user }

      assert_match(/Password is too short \(minimum is 12 characters\)/, error.message)
      assert_not_includes error.message, "short\n"
    end

    test "stops when the input ends" do
      User.delete_all

      error = assert_raises(CommandLine::Error) { command_line(input: "").create_user }

      assert_match(/No input/, error.message)
    end

    test "changes the password and ends every browser session" do
      owner = users(:owner)
      owner.sessions.create!

      command_line(input: "#{PASSWORD}\n#{PASSWORD}\n").change_password

      assert owner.reload.authenticate(PASSWORD)
      assert_empty owner.sessions
      assert_includes @output.string, "Every browser session has ended."
      assert_not_includes @output.string, PASSWORD
    end

    test "changes the password from an environment variable" do
      command_line(env: { "MONEY_BIN_PASSWORD" => PASSWORD }).change_password

      assert users(:owner).reload.authenticate(PASSWORD)
    end

    test "keeps the old password when the new one is not valid" do
      error = assert_raises(CommandLine::Error) { command_line(env: { "MONEY_BIN_PASSWORD" => "short" }).change_password }

      assert_match(/was not changed/, error.message)
      assert users(:owner).reload.authenticate(SessionTestHelper::OWNER_PASSWORD)
    end

    test "hides the typed password on a terminal" do
      terminal = Class.new(StringIO) do
        attr_reader :hidden_reads

        def tty? = true

        def noecho
          @hidden_reads = hidden_reads.to_i + 1
          yield self
        end
      end.new("#{PASSWORD}\n#{PASSWORD}\n")

      CommandLine.new(env: {}, input: terminal, output: @output).change_password

      assert_equal 2, terminal.hidden_reads
      assert users(:owner).reload.authenticate(PASSWORD)
    end

    test "cannot change a password before there is a user" do
      User.delete_all

      error = assert_raises(CommandLine::Error) { command_line.change_password }

      assert_match(/no user yet/, error.message)
    end

    test "the rake tasks use it and stop with the error message" do
      Rails.application.load_tasks if Rake::Task.tasks.none? { |task| task.name == "user:create" }
      _stdout, stderr = capture_io do
        assert_raises(SystemExit) { Rake::Task["user:create"].execute }
      end
      assert_match(/already a user/, stderr)

      with_env("MONEY_BIN_PASSWORD" => PASSWORD) do
        capture_io { Rake::Task["user:password"].execute }
      end
      assert users(:owner).reload.authenticate(PASSWORD)
    end

    private
      def with_env(values)
        previous = values.keys.index_with { |key| ENV[key] }
        values.each { |key, value| ENV[key] = value }
        yield
      ensure
        previous.each { |key, value| ENV[key] = value }
      end
  end
end
