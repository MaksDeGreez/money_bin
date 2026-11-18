import { Controller } from "@hotwired/stimulus"

// Live totals of a form that adds up amounts (ui/_totals_footer): the sum of the row amounts, the printed
// total, their difference and the QR total, recalculated as the person types.
//
//   form data-controller="money-totals" data-action="input->money-totals#update"
//     input data-money-totals-amount   (each row's amount; rows inside [hidden] are left out)
//     input data-money-totals-total    (the printed total, if the form has one)
//     dd data-money-totals-target="sum" / "total" / "difference"; p data-money-totals-target="status"
//
// Exact decimal arithmetic: amounts are read as BigInt hundredths (integer cents), never as floating point,
// with the rules of MoneyInput on the server (spaces dropped, a lone comma is the decimal separator, no
// exponent). More than two decimal places is "cannot be read", never rounded. These figures are a preview:
// the server's, shown after each save, are the authority.
const SPACES = /[\s   ]/g
const DECIMAL = /^-?(?:\d+(?:\.\d+)?|\.\d+)$/

// { cents: BigInt } for a decimal with at most two places, { blank: true }, or { invalid: true }.
export function parseMoney(text) {
  let value = (text ?? "").replace(SPACES, "").replace(/−/g, "-").replace(/^\+/, "")
  if (value === "") return { blank: true }
  if ((value.match(/,/g) || []).length === 1 && !value.includes(".")) value = value.replace(",", ".")
  if (!DECIMAL.test(value)) return { invalid: true }

  const negative = value.startsWith("-")
  if (negative) value = value.slice(1)
  const [whole, fraction = ""] = value.split(".")
  if (fraction.length > 2) return { invalid: true }

  const cents = BigInt((whole || "0") + fraction.padEnd(2, "0"))
  return { cents: negative ? -cents : cents }
}

// "1 250.40 UAH", as the server's receipt_money writes it.
export function formatMoney(cents, currency) {
  const negative = cents < 0n
  const abs = negative ? -cents : cents
  const whole = (abs / 100n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, " ")
  const fraction = (abs % 100n).toString().padStart(2, "0")
  return `${negative ? "-" : ""}${whole}.${fraction}${currency ? ` ${currency}` : ""}`
}

export default class extends Controller {
  static targets = ["sum", "total", "difference", "status"]
  static values = { qrTotal: String }

  update() {
    let sum = 0n
    let unreadable = 0
    for (const input of this.element.querySelectorAll("[data-money-totals-amount]")) {
      if (input.closest("[hidden]")) continue

      const amount = parseMoney(input.value)
      if (amount.invalid) unreadable += 1
      else if (amount.cents !== undefined) sum += amount.cents
    }

    const currency = this.currency
    let total = null
    const totalInput = this.element.querySelector("[data-money-totals-total]")
    if (totalInput) {
      const parsed = parseMoney(totalInput.value)
      if (parsed.invalid) unreadable += 1
      else if (parsed.cents !== undefined) total = parsed.cents
    }

    if (this.hasSumTarget) this.sumTarget.textContent = formatMoney(sum, currency)
    if (this.hasTotalTarget) this.totalTarget.textContent = total === null ? "—" : formatMoney(total, currency)
    if (this.hasDifferenceTarget) this.differenceTarget.textContent = total === null ? "—" : formatMoney(total - sum, currency)
    if (this.hasStatusTarget) this.statusTarget.textContent = this.status(sum, total, unreadable)
  }

  status(sum, total, unreadable) {
    if (unreadable > 0) return `${unreadable} amount${unreadable === 1 ? "" : "s"} cannot be read (a number such as 12.50, at most two decimals).`

    const notes = []
    const slip = this.element.querySelector("[data-receipt-review-target~='kind']")?.value === "card_slip"
    if (total !== null && !slip) {
      if (total === sum) notes.push("Items match the total.")
      else notes.push(total > sum ? "Items missing: they sum below the total." : "Items over the total.")
    }
    const qr = this.hasQrTotalValue && this.qrTotalValue ? parseMoney(this.qrTotalValue) : null
    if (qr?.cents !== undefined && total !== null && qr.cents !== total) notes.push("The total differs from the QR code.")
    return notes.join(" ")
  }

  get currency() {
    const field = this.element.querySelector("input[name$='[currency]']")
    return (field?.value || "").trim().toUpperCase()
  }
}
