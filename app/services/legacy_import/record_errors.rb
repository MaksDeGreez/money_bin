module LegacyImport
  # Runs a model write and turns its failure into an Error that names the row, the attributes and the kinds
  # of error. Active Record's own messages are never used: a validation message or a database error can
  # quote the value ("Name 'X' has already been taken", the SQL with its parameters).
  module RecordErrors
    module_function

    def save!(record, location)
      guard(location) { record.save! }
    end

    def guard(location)
      yield
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved, ActiveRecord::RecordNotDestroyed => error
      raise Error, "#{location}: the #{error.record.class.model_name.human.downcase} was refused " \
        "(#{describe(error.record)})"
    rescue ActiveRecord::StaleObjectError
      raise Error, "#{location}: the row changed in the database during the import"
    rescue ActiveRecord::ActiveRecordError => error
      raise Error, "#{location}: the database refused the row (#{error.class.name})"
    end

    # "name taken; lines.amount too_many_decimal_places". Error types are symbols (:taken, :blank), or the
    # fixed sentence a model passed to errors.add; neither carries the refused value.
    def describe(record)
      details = record.errors.details.flat_map do |attribute, list|
        list.map { |detail| "#{attribute} #{detail[:error]}" }
      end
      details.uniq.join("; ").presence || "no reason given"
    end
  end
end
