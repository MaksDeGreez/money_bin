require "test_helper"

class UserTest < ActiveSupport::TestCase
  PASSWORD = "a-long-enough-password"

  test "strips and downcases the e-mail address" do
    user = User.new(email_address: " OWNER@EXAMPLE.COM ")

    assert_equal "owner@example.com", user.email_address
  end

  test "the fixture owner signs in with the fixture password only" do
    owner = users(:owner)

    assert_equal owner, User.authenticate_by(email_address: "owner@example.com", password: SessionTestHelper::OWNER_PASSWORD)
    assert_nil User.authenticate_by(email_address: "owner@example.com", password: "wrong-password-here")
  end

  test "a second user cannot be created" do
    user = User.new(email_address: "second@example.com", password: PASSWORD)

    assert_not user.valid?
    assert_includes user.errors[:base], "There is already a user; this app has exactly one"
  end

  test "the database refuses a second user too" do
    assert_raises(ActiveRecord::RecordNotUnique) do
      User.insert!({ email_address: "second@example.com", password_digest: BCrypt::Password.create(PASSWORD) })
    end
  end

  test "the first user can be created when there is none" do
    User.delete_all

    user = User.create!(email_address: "first@example.com", password: PASSWORD)

    assert user.authenticate(PASSWORD)
  end

  test "the password needs a minimum length" do
    owner = users(:owner)
    owner.password = "a" * (User::PASSWORD_MIN_LENGTH - 1)

    assert_not owner.valid?
    assert owner.errors.added?(:password, :too_short, count: User::PASSWORD_MIN_LENGTH)

    owner.password = "a" * User::PASSWORD_MIN_LENGTH
    assert owner.valid?
  end

  test "the e-mail address must look like one" do
    owner = users(:owner)
    owner.email_address = "not an address"

    assert_not owner.valid?
    assert owner.errors.added?(:email_address, :invalid, value: "not an address")
  end

  test "there is no password reset token" do
    assert_not_respond_to users(:owner), :password_reset_token
    assert_not_respond_to User, :find_by_password_reset_token
  end

  test "changing the password ends every other session and keeps the current one" do
    owner = users(:owner)
    current = owner.sessions.create!
    other = owner.sessions.create!
    Current.session = current

    owner.update!(password: PASSWORD)

    assert Session.exists?(current.id)
    assert_not Session.exists?(other.id)
  ensure
    Current.reset
  end

  test "changing the password without a current session ends every session" do
    owner = users(:owner)
    owner.sessions.create!

    owner.update!(password: PASSWORD)

    assert_empty owner.sessions.reload
  end

  test "changing the e-mail address keeps the sessions" do
    owner = users(:owner)
    owner.sessions.create!

    owner.update!(email_address: "renamed@example.com")

    assert_equal 1, owner.sessions.count
  end
end
