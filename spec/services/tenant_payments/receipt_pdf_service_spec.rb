require "rails_helper"

RSpec.describe TenantPayments::ReceiptPdfService do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user, address: "123 Main St") }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }
  let(:payment) do
    create(:tenant_payment,
      tenancy: tenancy,
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

  it "renders receipt without transaction number when blank" do
    payment_without_txn = create(:tenant_payment,
      tenancy: tenancy,
      payment_date: Date.new(2026, 5, 1),
      amount: 1200,
      payment_method: "zelle",
      transaction_number: nil
    )
    allow(Prawn::Document).to receive(:new).and_return(pdf)

    result = described_class.call(tenant_payment: payment_without_txn, view_context: view_context)

    expect(result).to eq("pdf-data")
    expect(pdf).not_to have_received(:text).with(a_string_starting_with("Transaction Number:"))
  end

  it "renders receipt when tenancy has no property" do
    payment_record = create(:tenant_payment,
      user: user,
      tenancy: tenancy,
      payment_date: Date.new(2026, 5, 1),
      amount: 1200,
      payment_method: "zelle",
      transaction_number: "TXN123"
    )
    allow(payment_record.tenancy).to receive(:property).and_return(nil)
    allow(Prawn::Document).to receive(:new).and_return(pdf)

    result = described_class.call(tenant_payment: payment_record, view_context: view_context)
    expect(result).to eq("pdf-data")
    expect(pdf).to have_received(:text).with("Property: ")
  end
end
