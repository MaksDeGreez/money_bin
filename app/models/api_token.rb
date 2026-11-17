require "digest"

# A personal API token: how an AI agent or a script calls the REST API on the owner's behalf
# (Api::BaseController reads it from `Authorization: Bearer <token>`).
#
# The plain token is made by the app, never chosen by a person: the prefix `mbt_` ("Money Bin token")
# and 44 random base58 characters, about 257 bits of randomness. The prefix makes a leaked token easy to
# recognise in a log or for a secret scanner. The plain value is returned once, by ApiToken.issue, and the
# owner sees it once on the page that created it. It is never stored.
#
# Only `token_digest` is stored: the SHA-256 of the plain token, as 64 lower-case hex characters. A single
# fast hash is enough here. A slow password hash (bcrypt, Argon2) protects short, guessable passwords
# against guessing after a database leak; a 257-bit random token cannot be guessed at any hashing speed, so
# a slow hash would add nothing but cost on every request. A plain digest can also be looked up through a
# unique index, while a salted slow hash could not.
#
# `scope`: `read` allows the safe HTTP methods (GET, HEAD, OPTIONS); `read_write` allows every method.
#
# Tokens are revoked, never deleted, so the list keeps their history. A name is unique among the owner's
# active tokens; a revoked token's name can be used again.
class ApiToken < ApplicationRecord
  PREFIX = "mbt_".freeze
  RANDOM_LENGTH = 44
  # The prefix and exactly RANDOM_LENGTH base58 characters (no 0, O, I or l).
  FORMAT = /\A#{PREFIX}[1-9A-HJ-NP-Za-km-z]{#{RANDOM_LENGTH}}\z/
  DIGEST_FORMAT = /\A[0-9a-f]{64}\z/
  NAME_MAX_LENGTH = 100
  # last_used_at is written at most this often per token, so a busy agent does not cause a database write
  # on every request.
  LAST_USED_PRECISION = 1.minute

  enum :scope, { read: "read", read_write: "read_write" }, validate: true

  belongs_to :user

  scope :active, -> { where(revoked_at: nil) }
  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  normalizes :name, with: ->(value) { value.squish }

  validates :name, presence: true, length: { maximum: NAME_MAX_LENGTH },
    uniqueness: { scope: :user_id, conditions: -> { active }, if: :active? }
  validates :token_digest, presence: true, uniqueness: true, format: { with: DIGEST_FORMAT, allow_blank: true }

  # Creates a token for `user` and returns `[api_token, plain_token]`. The plain token is the only copy of
  # the secret: show it to the owner once and keep it nowhere. When the record is not valid it is not
  # saved, `plain_token` is nil, and `api_token.errors` says why.
  def self.issue(user:, name:, scope: :read)
    plain_token = generate_plain_token
    api_token = create(user:, name:, scope:, token_digest: digest(plain_token))
    [ api_token, (plain_token if api_token.persisted?) ]
  end

  # The active token whose plain value is `plain_token`, or nil for an unknown, malformed or revoked one.
  #
  # Timing: the only secret-dependent work is the index lookup of the digest. Its timing can say at most
  # something about digests that are near the digest of the attacker's own guess, and that does not help
  # to find a token: SHA-256 cannot be run backwards. A malformed value is turned away before any query.
  def self.find_active_by_plain_token(plain_token)
    return nil unless plain_token.is_a?(String) && FORMAT.match?(plain_token)

    active.find_by(token_digest: digest(plain_token))
  end

  def self.digest(plain_token)
    Digest::SHA256.hexdigest(plain_token)
  end

  def self.generate_plain_token
    PREFIX + SecureRandom.base58(RANDOM_LENGTH)
  end
  private_class_method :generate_plain_token

  def active?
    revoked_at.nil?
  end

  def revoked?
    !active?
  end

  # Stops the token working at once. The row stays, so the list keeps its history. Calling it again keeps
  # the first revocation time.
  def revoke!(at: Time.current)
    update!(revoked_at: at) if active?
  end

  # Records a use of the token. Writes only when the stored time is older than LAST_USED_PRECISION, and
  # without touching updated_at or running validations.
  def record_use!(at: Time.current)
    return if last_used_at && last_used_at > at - LAST_USED_PRECISION

    update_columns(last_used_at: at)
  end

  # Whether this token may make a request with the given HTTP method.
  def allows?(request_method)
    read_write? || %w[GET HEAD OPTIONS].include?(request_method.to_s.upcase)
  end
end
