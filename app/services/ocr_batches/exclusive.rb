module OcrBatches
  # Runs a block in one process at a time, across Sidekiq threads and processes: a PostgreSQL session advisory
  # lock, taken without waiting. Returns false (and runs nothing) when another run holds it. A worker that dies
  # loses its connection, and the lock with it, so a lock is never left behind.
  #
  #   OcrBatches::Exclusive.run(:poll) { ... }
  module Exclusive
    module_function

    def run(name)
      connection = ActiveRecord::Base.lease_connection
      key = Zlib.crc32("money_bin:ocr_batches:#{name}")
      return false unless connection.select_value("SELECT pg_try_advisory_lock(#{key})")

      begin
        yield
        true
      ensure
        connection.select_value("SELECT pg_advisory_unlock(#{key})")
      end
    end
  end
end
