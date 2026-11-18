# Pin npm packages by running ./bin/importmap

pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"

# Charts (the dashboard): Chart.js and Chartkick's JavaScript, both served from the chartkick gem (version
# locked in Gemfile.lock), and app/javascript/charts.js, which themes them. Not preloaded: only a page with
# a chart loads them, through charts_controller.js (docs/decisions/0013-dashboard-charts.md).
pin "Chart.bundle", to: "Chart.bundle.js", preload: false
pin "chartkick", to: "chartkick.js", preload: false
pin "charts", preload: false
