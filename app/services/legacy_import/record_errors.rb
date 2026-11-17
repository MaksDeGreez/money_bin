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

    # A message for an error added as a sentence, not as a type.
    CUSTOM = "invalid".freeze

    # "name taken; lines.amount invalid". An error type (:taken, :blank) is printed as it is. An error a model
    # added as a sentence is printed as CUSTOM: a sentence may quote a value ("UAH to USD"), and this text
    # goes to the terminal.
    def describe(record)
      details = record.errors.details.flat_map do |attribute, list|
        list.map { |detail| "#{attribute} #{detail[:error].is_a?(Symbol) ? detail[:error] : CUSTOM}" }
      end
      details.uniq.join("; ").presence || "no reason given"
    end
  end
end
