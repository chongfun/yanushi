class AddStatusAndErrorMessageToPaymentDocuments < ActiveRecord::Migration[8.1]
  def change
    add_column :payment_documents, :status, :string, default: "processing", null: false
    add_column :payment_documents, :error_message, :text
  end
end
