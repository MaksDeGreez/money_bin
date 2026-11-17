module LegacyImport
  # The transfer_id of an imported transfer: a UUID version 5 (RFC 9562, SHA-1 based) of the export's
  # `transfer_key` under NAMESPACE. The same key always gives the same id, on every run and every machine,
  # so an import that runs again finds the pair it wrote before.
  #
  # NAMESPACE is fixed for good: changing it would give every imported transfer a new id. It was generated
  # once at random and means nothing else.
  module TransferId
    NAMESPACE = "bdf1a284-e14e-4f36-a890-6310852e90d7".freeze

    module_function

    def for(transfer_key)
      Digest::UUID.uuid_v5(NAMESPACE, transfer_key)
    end
  end
end
