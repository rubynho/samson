# frozen_string_literal: true
class OutboundWebhookStage < ActiveRecord::Base
  belongs_to :outbound_webhook
  belongs_to :stage
end
