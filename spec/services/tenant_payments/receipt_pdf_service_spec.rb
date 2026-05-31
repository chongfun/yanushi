require "rails_helper"

RSpec.describe TenantPayments::ReceiptPdfService do
  let(:user) { create(:user) }
  let(:property) { create(:rental_property, user: user, address: "123 Main St") }
  let(:lease) { create(:lease, rental_property: property) }
  let(:payment) do
    create(:tenant_payment,
      lease: lease,
      payment_date: Date.new(2026, 5, 1),
      amount: 1200,
      payment_method: "zelle",
      transaction_number: "TXN123"
    )
  end
  let(:view_context) { double(number_to_currency: "$1,200.00") }
  let(:pdf) { instance_double(Prawn::Document, text: nil, move_down: nil, render: "pdf-data") }

  it "renders receipt details into a PDF" do
    allow(Prawn::Document).to receive(:new).and_return(pdf)

    result = described_class.call(tenant_payment: payment, view_context: view_context)

    expect(result).to eq("pdf-data")
    expect(pdf).to have_received(:text).with("Payment Receipt", size: 30, style: :bold)
    expect(pdf).to have_received(:text).with("Payment Date: 2026-05-01")
    expect(pdf).to have_received(:text).with("Amount: $1,200.00")
    expect(pdf).to have_received(:text).with("Method: zelle")
    expect(pdf).to have_received(:text).with("Transaction Number: TXN123")
    expect(pdf).to have_received(:text).with("Property: 123 Main St")
  end
end
