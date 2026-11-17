require "io/console"

module Users
  # The logic behind `bin/rails user:create` and `bin/rails user:password` (lib/tasks/user.rake). It lives
  # here, not in the rake file, so tests can drive it with plain strings instead of a terminal.
  #
  # Values come from environment variables when they are set (for scripted setups), else from questions on
  # the terminal. A typed password is not echoed and must be typed twice. Nothing here ever prints a
  # password.
  class CommandLine
    class Error < StandardError; end

    EMAIL_VARIABLE = "MONEY_BIN_EMAIL".freeze
    PASSWORD_VARIABLE = "MONEY_BIN_PASSWORD".freeze

    def initialize(env: ENV, input: $stdin, output: $stdout)
      @env = env
      @input = input
      @output = output
    end

    # Creates the one user and returns it. Raises Error when a user exists or the values are not valid.
    def create_user
      if (existing = User.first)
        raise Error, "There is already a user (#{existing.email_address}). This app has exactly one; " \
          "use bin/rails user:password to change its password."
      end

      email = from_env(EMAIL_VARIABLE) { ask("E-mail address: ") }
      password = from_env(PASSWORD_VARIABLE) { ask_new_password }
      user = User.new(email_address: email, password:)
      raise Error, "The user was not created: #{user.errors.full_messages.to_sentence}." unless user.save

      output.puts "Created the user #{user.email_address}. Sign in at /session/new."
      user
    end

    # Sets a new password for the one user and returns the user. Every browser session ends.
    def change_password
      user = User.first or raise Error, "There is no user yet. Run bin/rails user:create first."

      password = from_env(PASSWORD_VARIABLE) { ask_new_password }
      unless user.update(password:)
        raise Error, "The password was not changed: #{user.errors.full_messages.to_sentence}."
      end

      output.puts "Changed the password of #{user.email_address}. Every browser session has ended."
      user
    end

    private
      attr_reader :env, :input, :output

      def from_env(name)
        env[name].presence || yield
      end

      def ask_new_password
        password = ask_secret("Password (at least #{User::PASSWORD_MIN_LENGTH} characters): ")
        raise Error, "The passwords do not match." unless ask_secret("The same password again: ") == password

        password
      end

      def ask(prompt)
        output.print prompt
        read_line
      end

      # On a terminal the typed characters are hidden. Piped input is not echoed anyway.
      def ask_secret(prompt)
        output.print prompt
        line = input.tty? ? input.noecho { read_line } : read_line
        output.puts if input.tty?
        line
      end

      def read_line
        line = input.gets or raise Error, "No input: give the value on the terminal or in an environment variable."
        line.chomp
      end
  end
end
