# The Rails session cookie (CSRF token, flash, the page to return to after signing in).
#
# Browsers scope cookies by host, not by port, so every app served on localhost shares one cookie jar.
# Another local Rails app would use the default name built from the module name, which may be the same as
# ours. With a name of its own this app cannot sign that app out or break its CSRF tokens, and the other
# way round. The sign-in cookie has its own name for the same reason (Session::COOKIE_NAME).
Rails.application.config.session_store :cookie_store, key: "_money_bin_v2_session"
