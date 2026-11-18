# The owner: the one person who signs in through the browser. AI agents and scripts do not sign in; they
# use the owner's personal API tokens (ApiToken).
#
# There is exactly one user. There is no sign-up page: the user is created on the command line
# (`bin/rails user:create`), and a second one is refused here and by a unique index in the database
# (`index_users_single_row`). Ledger tables have no user_id: all data belongs to this one person.
#
# The password is hashed with bcrypt (has_secure_password). There is no password reset by e-mail, so the
# reset token that has_secure_password would add is turned off; `bin/rails user:password` sets a new
# password. Changing the password ends every other browser session.
class User < ApplicationRecord
  PASSWORD_MIN_LENGTH = 12
  EMAIL_FORMAT = /\A[^@\s]+@[^@\s]+\z/

  has_secure_password reset_token: false

  has_many :sessions, dependent: :delete_all
  has_many :api_tokens, dependent: :delete_all

  normalizes :email_address, with: ->(value) { value.strip.downcase }

  validates :email_address, presence: true, format: { with: EMAIL_FORMAT, allow_blank: true }
  # has_secure_password already checks presence on create and the 72-byte bcrypt limit.
  validates :password, length: { minimum: PASSWORD_MIN_LENGTH }, allow_nil: true
  validate :only_user, on: :create

  after_update :end_other_sessions, if: :saved_change_to_password_digest?

  private
    def only_user
      errors.add(:base, "There is already a user; this app has exactly one") if User.exists?
    end

    # Keeps the browser session that made the change (Current.session), if any. On the command line there
    # is none, so every session ends.
    def end_other_sessions
      ending = sessions.where.not(id: Current.session&.id)
      records = ending.includes(:user).to_a
      ending.delete_all
      Session.disconnect_sockets(records)
    end
end
