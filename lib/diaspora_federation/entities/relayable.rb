module DiasporaFederation
  module Entities
    # This is a module that defines common properties for relayable entities
    # which include Like, Comment, Participation, Message, etc. Each relayable
    # has a parent, identified by guid. Relayables are also signed and signing/verification
    # logic is embedded into Salmon XML processing code.
    module Relayable
      include Signable

      # Order from the parsed xml for signature
      # @return [Array] order from xml
      attr_reader :xml_order

      # Additional properties from parsed input object
      # @return [Hash] additional elements
      attr_reader :additional_data

      # On inclusion of this module the required properties for a relayable are added to the object that includes it.
      #
      # @!attribute [r] author
      #   The diaspora* ID of the author
      #   @see Person#author
      #   @return [String] diaspora* ID
      #
      # @!attribute [r] guid
      #   A random string of at least 16 chars
      #   @see Validation::Rule::Guid
      #   @return [String] comment guid
      #
      # @!attribute [r] parent_guid
      #   @see StatusMessage#guid
      #   @return [String] parent guid
      #
      # @!attribute [r] author_signature
      #   Contains a signature of the entity using the private key of the author of a post itself
      #   The presence of this signature is mandatory. Without it the entity won't be accepted by
      #   a target pod.
      #   @return [String] author signature
      #
      # @!attribute [r] parent_author_signature
      #   Contains a signature of the entity using the private key of the author of a parent post
      #   This signature is required only when federating from upstream (parent) post author to
      #   downstream subscribers. This is the case when the parent author has to resend a relayable
      #   received from one of their subscribers to all others.
      #   @return [String] parent author signature
      #
      # @!attribute [r] parent
      #   Meta information about the parent object
      #   @return [RelatedEntity] parent entity
      #
      # @param [Entity] klass the entity in which it is included
      def self.included(klass)
        klass.class_eval do
          property :author, :string, xml_name: :diaspora_handle
          property :guid, :string
          property :parent_guid, :string
          property :author_signature, :string, default: nil
          property :parent_author_signature, :string, default: nil
          entity :parent, Entities::RelatedEntity
        end

        klass.extend Parsing
      end

      # Initializes a new relayable Entity with order and additional xml elements
      #
      # @param [Hash] data entity data
      # @param [Array] xml_order order from xml
      # @param [Hash] additional_data additional xml elements
      # @see DiasporaFederation::Entity#initialize
      def initialize(data, xml_order=nil, additional_data={})
        @xml_order = xml_order.reject {|name| name =~ /signature/ } if xml_order
        @additional_data = additional_data

        super(data)
      end

      # Verifies the signatures (+author_signature+ and +parent_author_signature+ if needed).
      # @raise [SignatureVerificationFailed] if the signature is not valid
      # @raise [PublicKeyNotFound] if no public key is found
      def verify_signatures
        verify_signature(author, :author_signature)

        # This happens only on downstream federation.
        verify_signature(parent.author, :parent_author_signature) unless parent.local
      end

      def sender_valid?(sender)
        sender == author || sender == parent.author
      end

      # @return [String] string representation of this object
      def to_s
        "#{super}#{":#{parent_type}" if respond_to?(:parent_type)}:#{parent_guid}"
      end

      def to_json
        super.merge!(property_order: signature_order).tap {|json_hash|
          missing_properties = json_hash[:property_order] - json_hash[:entity_data].keys
          missing_properties.each {|property|
            json_hash[:entity_data][property] = nil
          }
        }
      end

      private

      # Sign with author key
      # @raise [AuthorPrivateKeyNotFound] if the author private key is not found
      # @return [String] A Base64 encoded signature of #signature_data with key
      def sign_with_author
        privkey = DiasporaFederation.callbacks.trigger(:fetch_private_key, author)
        raise AuthorPrivateKeyNotFound, "author=#{author} obj=#{self}" if privkey.nil?
        sign_with_key(privkey).tap do
          logger.info "event=sign status=complete signature=author_signature author=#{author} obj=#{self}"
        end
      end

      # Sign with parent author key, if the parent author is local (if the private key is found)
      # @return [String] A Base64 encoded signature of #signature_data with key
      def sign_with_parent_author_if_available
        privkey = DiasporaFederation.callbacks.trigger(:fetch_private_key, parent.author)
        return unless privkey

        sign_with_key(privkey).tap do
          logger.info "event=sign status=complete signature=parent_author_signature obj=#{self}"
        end
      end

      # Update the signatures with the keys of the author and the parent
      # if the signatures are not there yet and if the keys are available.
      #
      # @return [Hash] properties with updated signatures
      def enriched_properties
        super.merge(additional_data).tap do |hash|
          hash[:author_signature] = author_signature || sign_with_author
          hash[:parent_author_signature] = parent_author_signature || sign_with_parent_author_if_available.to_s
        end
      end

      # Sort all XML elements according to the order used for the signatures.
      #
      # @return [Hash] sorted xml elements
      def xml_elements
        data = super
        order = signature_order + %i(author_signature parent_author_signature)
        order.map {|element| [element, data[element] || ""] }.to_h
      end

      # The order for signing
      # @return [Array]
      def signature_order
        if xml_order
          prop_names = self.class.class_props.keys.map(&:to_s)
          xml_order.map {|name| prop_names.include?(name) ? name.to_sym : name }
        else
          self.class::LEGACY_SIGNATURE_ORDER
        end
      end

      # @return [String] signature data string
      def signature_data
        data = normalized_properties.merge(additional_data)
        signature_order.map {|name| data[name] }.join(";")
      end

      # Override class methods from {Entity} to parse serialized data
      module Parsing
        # Does the same job as Entity.from_hash except of the following differences:
        # 1) unknown properties from the properties_hash are stored to additional_data of the relayable instance
        # 2) parent entity fetch is attempted
        # 3) signatures verification is performed; property_order is used as the order in which properties are composed
        # to compute signatures
        # 4) unknown properties' keys must be of String type
        #
        # @see Entity.from_hash
        def from_hash(properties_hash, property_order)
          # Use all known properties to build the Entity (entity_data). All additional elements
          # are respected and attached to a hash as string (additional_data). This is needed
          # to support receiving objects from the future versions of diaspora*, where new elements may have been added.
          additional_data = properties_hash.reject {|key, _| class_props.has_key?(key) }

          fetch_parent(properties_hash)
          new(properties_hash, property_order, additional_data).tap(&:verify_signatures)
        end

        private

        def fetch_parent(data)
          type = data.fetch(:parent_type) {
            break self::PARENT_TYPE if const_defined?(:PARENT_TYPE)

            raise DiasporaFederation::Entity::ValidationError, "invalid #{self}! missing 'parent_type'."
          }
          guid = data.fetch(:parent_guid) {
            raise DiasporaFederation::Entity::ValidationError, "invalid #{self}! missing 'parent_guid'."
          }

          data[:parent] = DiasporaFederation.callbacks.trigger(:fetch_related_entity, type, guid)

          return if data[:parent]

          # Fetch and receive parent from remote, if not available locally
          Federation::Fetcher.fetch_public(data[:author], type, guid)
          data[:parent] = DiasporaFederation.callbacks.trigger(:fetch_related_entity, type, guid)
        end

        def xml_parser_class
          DiasporaFederation::Parsers::RelayableXmlParser
        end

        def json_parser_class
          DiasporaFederation::Parsers::RelayableJsonParser
        end
      end

      # Raised, if creating the author_signature fails, because the private key was not found
      class AuthorPrivateKeyNotFound < RuntimeError
      end
    end
  end
end
