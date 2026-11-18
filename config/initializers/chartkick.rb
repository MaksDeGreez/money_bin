# Chartkick draws each chart from a small inline <script> that carries the page's Content Security Policy
# nonce (the helper reads content_security_policy_nonce). Its default container has an inline style
# attribute, which the policy blocks (a nonce does not cover style attributes), so the container is a class
# instead: `chart` and a height class `chart-<height>` (`height: "md"` gives `chart-md`, sized in
# app/assets/tailwind/design-system.css). The canvas is hidden from screen readers: each chart has the same
# figures as a table next to it. docs/decisions/0013-dashboard-charts.md
Chartkick.options[:html] = '<div id="%{id}" class="chart chart-%{height}" aria-hidden="true"></div>'
Chartkick.options[:height] = "md"
