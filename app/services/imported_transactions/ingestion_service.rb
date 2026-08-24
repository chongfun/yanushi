require "stringio"
require "hexapdf"

module ImportedTransactions
  class IngestionService
    PARSERS = {
      "zelle" => Parsers::Zelle,
      "venmo" => Parsers::Venmo
    }.freeze

    def self.call(user:, pdf_path_or_io:, source: "pdf_upload")
      new.call(user: user, pdf_path_or_io: pdf_path_or_io, source: source)
    end

    def call(user:, pdf_path_or_io:, source: "pdf_upload")
      if pdf_path_or_io.is_a?(SourceDocument)
        return ServiceResult.failure(error: "Source document was not found.", code: :not_found) if pdf_path_or_io.user_id != user.id

        source_document = pdf_path_or_io
        source_document.with_lock do
          source_document.reload

          if source_document.success?
            existing = source_document.imported_transactions.to_a
            return ServiceResult.success(source_document: source_document, imported_transactions: existing)
          end

          Time.use_zone(user.timezone) do
            _pdf_bytes, _filename, page_count, raw_text, _ = extract_pdf_data(source_document, user)
            process_document(user: user, source: source, raw_text: raw_text, page_count: page_count, source_document: source_document)
          end
        end
      else
        Time.use_zone(user.timezone) do
          pdf_bytes, _filename, page_count, raw_text, source_document = extract_pdf_data(pdf_path_or_io, user)

          if source_document.new_record?
            begin
              source_document.save!
            rescue ActiveRecord::RecordNotUnique
              source_document = user.source_documents.find_by!(attachment_sha256: Digest::SHA256.hexdigest(pdf_bytes))
            rescue ActiveRecord::RecordInvalid => e
              if e.record.errors[:attachment_sha256].any?
                source_document = user.source_documents.find_by!(attachment_sha256: Digest::SHA256.hexdigest(pdf_bytes))
              else
                raise e
              end
            end
          end

          source_document.with_lock do
            source_document.reload

            if source_document.success?
              existing = source_document.imported_transactions.to_a
              return ServiceResult.success(source_document: source_document, imported_transactions: existing)
            end

            process_document(user: user, source: source, raw_text: raw_text, page_count: page_count, source_document: source_document)
          end
        end
      end
    end

    private

      def process_document(user:, source:, raw_text:, page_count:, source_document:)
        doc_type = detect_type(raw_text)
        source_document.document_type = doc_type

        if doc_type == "unknown"
          source_document.status = "failed"
          source_document.error_message = "Unrecognized document format"
          source_document.save!
          return ServiceResult.failure(error: "Unrecognized document format", code: :unrecognized_format)
        end

        if doc_type != "chase_statement" && page_count > 1
          source_document.status = "failed"
          source_document.error_message = "Multi-page statement PDFs are not supported"
          source_document.save!
          return ServiceResult.failure(error: "Multi-page statement PDFs are not supported", code: :unsupported_pages)
        end

        # Parse results
        parser_results = if doc_type == "chase_statement"
          Parsers::ChaseStatement.new.parse(raw_text)
        else
          parser = PARSERS[doc_type].new
          res = parser.parse(raw_text)
          res.is_a?(Array) ? res : [ res ]
        end

        transactions = build_transactions(
          user: user,
          source: source,
          document_type: doc_type,
          parser_results: parser_results,
          raw_text: raw_text,
          source_document: source_document
        )

        if doc_type == "chase_statement" && transactions.empty?
          source_document.status = "failed"
          source_document.error_message = "No matching tenant transactions found"
          source_document.save!
          return ServiceResult.failure(error: "No matching tenant transactions found", code: :no_transactions_found)
        end

        # Persist transactions atomically
        persisted_transactions = [] # : Array[ImportedTransaction]
        transactions.each do |txn|
          begin
            txn.save!
            persisted_transactions << txn
          rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
            # Skip duplicate transaction on concurrent insert
            duplicate_error = e.is_a?(ActiveRecord::RecordNotUnique) ||
                              txn.errors.added?(:external_reference, :taken)

            if duplicate_error
              next
            else
              raise e
            end
          end
        end

        source_document.status = "success"
        source_document.save!

        ServiceResult.success(source_document: source_document, imported_transactions: persisted_transactions)
      end

      def extract_pdf_data(pdf_path_or_io, user)
        if pdf_path_or_io.is_a?(SourceDocument)
          source_document = pdf_path_or_io
          pdf_bytes = source_document.has_attribute?(:attachment_file) ? source_document.attachment_file : SourceDocument.where(id: source_document.id).pluck(:attachment_file).first
          raise StandardError, "Source document is missing attachment data" unless pdf_bytes

          filename = source_document.attachment_filename
          io = StringIO.new(pdf_bytes)
          doc = HexaPDF::Document.new(io: io)
        else
          pdf_bytes = read_pdf_bytes(pdf_path_or_io)

          doc = HexaPDF::Document.new(io: StringIO.new(pdf_bytes))

          filename = if pdf_path_or_io.respond_to?(:original_filename)
            pdf_path_or_io.original_filename
          elsif pdf_path_or_io.respond_to?(:path)
            File.basename(pdf_path_or_io.path)
          else
            File.basename(pdf_path_or_io.to_s)
          end
          filename = "receipt.pdf" if filename.blank? || filename.include?("#<")

          sha256 = Digest::SHA256.hexdigest(pdf_bytes)
          source_document = user.source_documents.find_by(attachment_sha256: sha256) || SourceDocument.new(
            user: user,
            attachment_file: pdf_bytes,
            attachment_filename: filename,
            attachment_content_type: "application/pdf",
            attachment_sha256: sha256
          )
        end

        page_count = doc.pages.count

        raw_text = doc.pages.map do |page|
          page.extract_text rescue ""
        end.join("\n")

        [ pdf_bytes, filename || "receipt.pdf", page_count, raw_text, source_document ]
      end

      def read_pdf_bytes(pdf_path_or_io)
        if pdf_path_or_io.respond_to?(:read)
          pdf_path_or_io.rewind if pdf_path_or_io.respond_to?(:rewind)
          bytes = pdf_path_or_io.read.to_s
          pdf_path_or_io.rewind if pdf_path_or_io.respond_to?(:rewind)
          bytes
        elsif File.exist?(pdf_path_or_io.to_s)
          File.binread(pdf_path_or_io.to_s)
        else
          pdf_path_or_io.to_s
        end
      end

      def detect_type(text)
        if text.match?(/CHASE/i) && text.match?(/TRANSACTION DETAIL/i)
          "chase_statement"
        elsif text.match?(/Transaction ID\s+\d+/i) || text.match?(/venmo/i)
          "venmo"
        elsif text.match?(/zelle/i) || text.match?(/Transaction number/i) || text.match?(/sent you money/i)
          "zelle"
        else
          "unknown"
        end
      end

      def build_transactions(user:, source:, document_type:, parser_results:, raw_text:, source_document:)
        transactions = [] # : Array[ImportedTransaction]
        seen_keys = Set.new

        parser_results.each do |parser_result|
          if parser_result.success?
            result = parser_result.value!

            # Skip creating candidate if duplicate external identity already exists
            if result.external_reference.present? && result.payment_method.present?
              ext_key = [ source, result.payment_method, result.external_reference ]
              next if seen_keys.include?(ext_key)

              seen_keys.add(ext_key)

              existing = user.imported_transactions.where(
                source: source,
                payment_method: result.payment_method,
                external_reference: result.external_reference
              ).exists?
              next if existing
            end

            resolve_result = PartyResolver.new.resolve(user, result.payer_name, result.payer_username)
            party = resolve_result.success? ? resolve_result.value!.party : resolve_result.failure.party
            status = resolve_result.success? ? resolve_result.value!.status : resolve_result.failure.status
            tenancy = nil

            if party && result.occurred_on.present?
              active_tenancies = party.tenancies.select { |t| t.active?(result.occurred_on) }
              if active_tenancies.size == 1
                tenancy = active_tenancies.first
              elsif active_tenancies.size > 1
                status = :ambiguous if status.to_s == "matched"
              end
            end

            transactions << ImportedTransaction.new(
              user: user,
              source: source,
              source_document: source_document,
              transaction_kind: "unknown",
              status: status,
              payer_name: result.payer_name,
              payer_username: result.payer_username,
              amount_cents: result.amount_cents,
              occurred_on: result.occurred_on,
              payment_method: result.payment_method,
              external_reference: result.external_reference,
              raw_text: result.raw_text,
              matched_party: party,
              matched_tenancy: tenancy
            )
          else
            result = parser_result.failure

            unless document_type == "chase_statement"
              transactions << ImportedTransaction.new(
                user: user,
                source: source,
                source_document: source_document,
                transaction_kind: "unknown",
                status: :failed,
                raw_text: raw_text,
                error_message: result.error_message
              )
            end
          end
        end

        transactions
      end
  end
end
