# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc
]

# What a person types into the receipt review form and manual entry (merchants, items, amounts, card digits)
# stays out of the request log: the forms post it as `receipt[...]` and `manual_expense[...]`.
Rails.application.config.filter_parameters += [ /\Areceipt\z/, /\Amanual_expense\z/ ]
