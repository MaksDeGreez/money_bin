# The home page: the dashboard (Dashboard), for the period and currency in the URL.
class HomeController < ApplicationController
  def show
    @dashboard = Dashboard.new(params.permit(*Dashboard::KEYS))
  end
end
