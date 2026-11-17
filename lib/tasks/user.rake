# The app has one user and no sign-up page, so the user is created here. See Users::CommandLine.
namespace :user do
  desc "Create the one user (asks on the terminal, or reads MONEY_BIN_EMAIL and MONEY_BIN_PASSWORD)"
  task create: :environment do
    Users::CommandLine.new.create_user
  rescue Users::CommandLine::Error => error
    abort error.message
  end

  desc "Set a new password for the user and end every browser session (asks, or reads MONEY_BIN_PASSWORD)"
  task password: :environment do
    Users::CommandLine.new.change_password
  rescue Users::CommandLine::Error => error
    abort error.message
  end
end
