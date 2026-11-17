class ApplicationController < ActionController::Base
  # Every page needs a signed-in session, except where a controller says otherwise.
  include Authentication

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  # Every form_with gets the design-system fields.
  default_form_builder UiFormBuilder
end
