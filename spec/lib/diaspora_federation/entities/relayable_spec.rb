module DiasporaFederation
  describe Entities::Relayable do
    let(:author_pkey) { OpenSSL::PKey::RSA.generate(1024) }
    let(:parent_pkey) { OpenSSL::PKey::RSA.generate(1024) }

    let(:guid) { FactoryGirl.generate(:guid) }
    let(:parent_guid) { FactoryGirl.generate(:guid) }
    let(:author) { FactoryGirl.generate(:diaspora_id) }
    let(:property) { "hello" }
    let(:new_property) { "some text" }
    let(:local_parent) { FactoryGirl.build(:related_entity, author: bob.diaspora_id) }
    let(:remote_parent) { FactoryGirl.build(:related_entity, author: bob.diaspora_id, local: false) }
    let(:hash) { {guid: guid, author: author, parent_guid: parent_guid, parent: local_parent, property: property} }
    let(:hash_with_fake_signatures) { hash.merge!(author_signature: "aa", parent_author_signature: "bb") }

    let(:legacy_signature_data) { "#{guid};#{author};#{property};#{parent_guid}" }

    describe "#initialize" do
      it "filters signatures from order" do
        xml_order = [:author, :guid, :parent_guid, :property, "new_property", :author_signature]

        expect(Entities::SomeRelayable.new(hash, xml_order).xml_order)
          .to eq([:author, :guid, :parent_guid, :property, "new_property"])
      end
    end

    describe "#verify_signatures" do
      it "doesn't raise anything if correct signatures with legacy-string were passed" do
        hash[:author_signature] = sign_with_key(author_pkey, legacy_signature_data)
        hash[:parent_author_signature] = sign_with_key(parent_pkey, legacy_signature_data)
        hash[:parent] = remote_parent

        expect_callback(:fetch_public_key, author).and_return(author_pkey.public_key)
        expect_callback(:fetch_public_key, remote_parent.author).and_return(parent_pkey.public_key)

        expect { Entities::SomeRelayable.new(hash).verify_signatures }.not_to raise_error
      end

      it "raises when no public key for author was fetched" do
        expect_callback(:fetch_public_key, anything).and_return(nil)

        expect {
          Entities::SomeRelayable.new(hash).verify_signatures
        }.to raise_error Entities::Relayable::PublicKeyNotFound
      end

      it "raises when bad author signature was passed" do
        hash[:author_signature] = nil

        expect_callback(:fetch_public_key, author).and_return(author_pkey.public_key)

        expect {
          Entities::SomeRelayable.new(hash).verify_signatures
        }.to raise_error Entities::Relayable::SignatureVerificationFailed
      end

      it "raises when no public key for parent author was fetched" do
        hash[:author_signature] = sign_with_key(author_pkey, legacy_signature_data)
        hash[:parent] = remote_parent

        expect_callback(:fetch_public_key, author).and_return(author_pkey.public_key)
        expect_callback(:fetch_public_key, remote_parent.author).and_return(nil)

        expect {
          Entities::SomeRelayable.new(hash).verify_signatures
        }.to raise_error Entities::Relayable::PublicKeyNotFound
      end

      it "raises when bad parent author signature was passed" do
        hash[:author_signature] = sign_with_key(author_pkey, legacy_signature_data)
        hash[:parent_author_signature] = nil
        hash[:parent] = remote_parent

        expect_callback(:fetch_public_key, author).and_return(author_pkey.public_key)
        expect_callback(:fetch_public_key, remote_parent.author).and_return(parent_pkey.public_key)

        expect {
          Entities::SomeRelayable.new(hash).verify_signatures
        }.to raise_error Entities::Relayable::SignatureVerificationFailed
      end

      it "doesn't raise if parent_author_signature isn't set but we're on upstream federation" do
        hash[:author_signature] = sign_with_key(author_pkey, legacy_signature_data)
        hash[:parent_author_signature] = nil
        hash[:parent] = local_parent

        expect_callback(:fetch_public_key, author).and_return(author_pkey.public_key)

        expect { Entities::SomeRelayable.new(hash).verify_signatures }.not_to raise_error
      end

      context "new signatures" do
        it "doesn't raise anything if correct signatures with new order were passed" do
          xml_order = %i(author guid parent_guid property)
          signature_data = "#{author};#{guid};#{parent_guid};#{property}"

          hash[:author_signature] = sign_with_key(author_pkey, signature_data)
          hash[:parent_author_signature] = sign_with_key(parent_pkey, signature_data)
          hash[:parent] = remote_parent

          expect_callback(:fetch_public_key, author).and_return(author_pkey.public_key)
          expect_callback(:fetch_public_key, remote_parent.author).and_return(parent_pkey.public_key)

          expect { Entities::SomeRelayable.new(hash, xml_order).verify_signatures }.not_to raise_error
        end

        it "doesn't raise anything if correct signatures with new property were passed" do
          xml_order = [:author, :guid, :parent_guid, :property, "new_property"]
          signature_data_with_new_property = "#{author};#{guid};#{parent_guid};#{property};#{new_property}"

          hash[:author_signature] = sign_with_key(author_pkey, signature_data_with_new_property)
          hash[:parent_author_signature] = sign_with_key(parent_pkey, signature_data_with_new_property)
          hash[:parent] = remote_parent

          expect_callback(:fetch_public_key, author).and_return(author_pkey.public_key)
          expect_callback(:fetch_public_key, remote_parent.author).and_return(parent_pkey.public_key)

          expect {
            Entities::SomeRelayable.new(hash, xml_order, "new_property" => new_property).verify_signatures
          }.not_to raise_error
        end

        it "raises with legacy-signatures and with new property and order" do
          hash[:author_signature] = sign_with_key(author_pkey, legacy_signature_data)

          expect_callback(:fetch_public_key, author).and_return(author_pkey.public_key)

          xml_order = [:author, :guid, :parent_guid, :property, "new_property"]
          expect {
            Entities::SomeRelayable.new(hash, xml_order, "new_property" => new_property).verify_signatures
          }.to raise_error Entities::Relayable::SignatureVerificationFailed
        end
      end
    end

    describe "#to_xml" do
      let(:expected_xml) { <<-XML }
<some_relayable>
  <diaspora_handle>#{author}</diaspora_handle>
  <guid>#{guid}</guid>
  <parent_guid>#{parent_guid}</parent_guid>
  <property>#{property}</property>
  <new_property>#{new_property}</new_property>
  <author_signature>aa</author_signature>
  <parent_author_signature>bb</parent_author_signature>
</some_relayable>
XML

      it "adds new unknown xml elements to the xml again" do
        xml_order = [:author, :guid, :parent_guid, :property, "new_property"]
        xml = Entities::SomeRelayable.new(hash_with_fake_signatures, xml_order, "new_property" => new_property).to_xml

        expect(xml.to_s.strip).to eq(expected_xml.strip)
      end

      it "converts strings in xml_order to symbol if needed" do
        xml_order = %w(author guid parent_guid property new_property)
        xml = Entities::SomeRelayable.new(hash_with_fake_signatures, xml_order, "new_property" => new_property).to_xml

        expect(xml.to_s.strip).to eq(expected_xml.strip)
      end

      it "adds missing properties from xml_order to xml" do
        xml_order = [:author, :guid, :parent_guid, :property, "new_property"]

        xml = Entities::SomeRelayable.new(hash_with_fake_signatures, xml_order).to_xml

        expect(xml.at_xpath("new_property").text).to be_empty
      end

      it "computes correct signatures for the entity" do
        expect_callback(:fetch_private_key, author).and_return(author_pkey)
        expect_callback(:fetch_private_key, local_parent.author).and_return(parent_pkey)

        xml = Entities::SomeRelayable.new(hash).to_xml

        author_signature = xml.at_xpath("author_signature").text
        parent_author_signature = xml.at_xpath("parent_author_signature").text

        expect(verify_signature(author_pkey, author_signature, legacy_signature_data)).to be_truthy
        expect(verify_signature(parent_pkey, parent_author_signature, legacy_signature_data)).to be_truthy
      end

      it "computes correct signatures for the entity with new unknown xml elements" do
        expect_callback(:fetch_private_key, author).and_return(author_pkey)
        expect_callback(:fetch_private_key, local_parent.author).and_return(parent_pkey)

        xml_order = [:author, :guid, :parent_guid, "new_property", :property]
        signature_data_with_new_property = "#{author};#{guid};#{parent_guid};#{new_property};#{property}"

        xml = Entities::SomeRelayable.new(hash, xml_order, "new_property" => new_property).to_xml

        author_signature = xml.at_xpath("author_signature").text
        parent_author_signature = xml.at_xpath("parent_author_signature").text

        expect(verify_signature(author_pkey, author_signature, signature_data_with_new_property)).to be_truthy
        expect(verify_signature(parent_pkey, parent_author_signature, signature_data_with_new_property)).to be_truthy
      end

      it "doesn't change signatures if they are already set" do
        xml = Entities::SomeRelayable.new(hash_with_fake_signatures).to_xml

        expect(xml.at_xpath("author_signature").text).to eq("aa")
        expect(xml.at_xpath("parent_author_signature").text).to eq("bb")
      end

      it "raises when author_signature not set and key isn't supplied" do
        expect_callback(:fetch_private_key, author).and_return(nil)

        expect {
          Entities::SomeRelayable.new(hash).to_xml
        }.to raise_error Entities::Relayable::AuthorPrivateKeyNotFound
      end

      it "doesn't set parent_author_signature if key isn't supplied" do
        expect_callback(:fetch_private_key, author).and_return(author_pkey)
        expect_callback(:fetch_private_key, local_parent.author).and_return(nil)

        xml = Entities::SomeRelayable.new(hash).to_xml

        expect(xml.at_xpath("parent_author_signature").text).to eq("")
      end
    end

    describe ".from_xml" do
      context "parsing" do
        before do
          expect_callback(:fetch_related_entity, "Parent", parent_guid).and_return(remote_parent)
          expect_callback(:fetch_public_key, author).and_return(author_pkey.public_key)
          expect_callback(:fetch_public_key, remote_parent.author).and_return(parent_pkey.public_key)
        end

        let(:new_signature_data) { "#{author};#{guid};#{parent_guid};#{new_property};#{property}" }
        let(:new_xml) { <<-XML }
<some_relayable>
  <diaspora_handle>#{author}</diaspora_handle>
  <guid>#{guid}</guid>
  <parent_guid>#{parent_guid}</parent_guid>
  <new_property>#{new_property}</new_property>
  <property>#{property}</property>
  <author_signature>#{sign_with_key(author_pkey, new_signature_data)}</author_signature>
  <parent_author_signature>#{sign_with_key(parent_pkey, new_signature_data)}</parent_author_signature>
</some_relayable>
XML

        it "doesn't drop unknown properties" do
          entity = Entities::SomeRelayable.from_xml(Nokogiri::XML::Document.parse(new_xml).root)

          expect(entity).to be_an_instance_of Entities::SomeRelayable
          expect(entity.property).to eq(property)
          expect(entity.additional_data).to eq(
            "new_property" => new_property
          )
        end

        it "hand over the order in the xml to the instance without signatures" do
          entity = Entities::SomeRelayable.from_xml(Nokogiri::XML::Document.parse(new_xml).root)

          expect(entity.xml_order).to eq([:author, :guid, :parent_guid, "new_property", :property])
        end

        it "creates Entity with empty 'additional_data' if the xml has only known properties" do
          hash[:author_signature] = sign_with_key(author_pkey, legacy_signature_data)
          hash[:parent_author_signature] = sign_with_key(parent_pkey, legacy_signature_data)

          xml = Entities::SomeRelayable.new(hash).to_xml

          entity = Entities::SomeRelayable.from_xml(xml)

          expect(entity).to be_an_instance_of Entities::SomeRelayable
          expect(entity.property).to eq(property)
          expect(entity.additional_data).to be_empty
        end
      end

      context "parse invalid XML" do
        it "raises a ValidationError if the parent_guid is missing" do
          broken_xml = <<-XML
<some_relayable>
  <author_signature/>
  <parent_author_signature/>
</some_relayable>
XML

          expect {
            Entities::SomeRelayable.from_xml(Nokogiri::XML::Document.parse(broken_xml).root)
          }.to raise_error Entity::ValidationError,
                           "invalid DiasporaFederation::Entities::SomeRelayable! missing 'parent_guid'."
        end
      end
    end

    describe "#to_json" do
      let(:entity_class) { Entities::SomeRelayable }

      it "contains the property order within the property_order property" do
        property_order = %i(author guid parent_guid property)
        json = entity_class.new(hash_with_fake_signatures, property_order).to_json.to_json

        expect(json).to include_json(property_order: property_order.map(&:to_s))
      end

      it "uses legacy order for filling property_order when no xml_order supplied" do
        entity = entity_class.new(hash_with_fake_signatures)
        expect(
          entity.to_json.to_json
        ).to include_json(property_order: entity_class::LEGACY_SIGNATURE_ORDER.map(&:to_s))
      end

      it "adds new unknown elements to the json again" do
        property_order = [:author, :guid, :parent_guid, :property, "new_property"]
        json = Entities::SomeRelayable.new(hash_with_fake_signatures, property_order, "new_property" => new_property)
                                      .to_json.to_json

        expect(json).to include_json(
          entity_data:    {new_property: new_property},
          property_order: {4 => "new_property"}
        )
      end

      it "adds missing properties from property order to json" do
        property_order = [:author, :guid, :parent_guid, :property, "new_property"]
        json = Entities::SomeRelayable.new(hash_with_fake_signatures, property_order).to_json.to_json

        expect(json).to include_json(
          entity_data:    {new_property: nil},
          property_order: {4 => "new_property"}
        )
      end

      it "computes correct signatures for the entity with new unknown elements" do
        expect_callback(:fetch_private_key, author).and_return(author_pkey)
        expect_callback(:fetch_private_key, local_parent.author).and_return(parent_pkey)

        property_order = [:author, :guid, :parent_guid, "new_property", :property]
        signature_data_with_new_property = "#{author};#{guid};#{parent_guid};#{new_property};#{property}"

        json_hash = Entities::SomeRelayable.new(hash, property_order, "new_property" => new_property).to_json
        author_signature = json_hash[:entity_data][:author_signature]
        parent_author_signature = json_hash[:entity_data][:parent_author_signature]

        expect(verify_signature(author_pkey, author_signature, signature_data_with_new_property)).to be_truthy
        expect(verify_signature(parent_pkey, parent_author_signature, signature_data_with_new_property)).to be_truthy
      end

      it "doesn't change signatures if they are already set" do
        json = Entities::SomeRelayable.new(hash_with_fake_signatures).to_json.to_json
        expect(json).to include_json(entity_data: {author_signature: "aa"})
        expect(json).to include_json(entity_data: {parent_author_signature: "bb"})
      end

      it "raises when author_signature not set and key isn't supplied" do
        expect_callback(:fetch_private_key, author).and_return(nil)

        expect {
          Entities::SomeRelayable.new(hash).to_json
        }.to raise_error Entities::Relayable::AuthorPrivateKeyNotFound
      end

      it "doesn't set parent_author_signature if key isn't supplied" do
        expect_callback(:fetch_private_key, author).and_return(author_pkey)
        expect_callback(:fetch_private_key, local_parent.author).and_return(nil)

        json = Entities::SomeRelayable.new(hash).to_json.to_json
        expect(json).to include_json(entity_data: {parent_author_signature: ""})
      end
    end

    describe ".from_hash" do
      let(:entity_class) { Entities::SomeRelayable }

      context "parsing" do
        before do
          expect_callback(:fetch_related_entity, "Parent", parent_guid).and_return(remote_parent)
          expect_callback(:fetch_public_key, author).and_return(author_pkey.public_key)
          expect_callback(:fetch_public_key, remote_parent.author).and_return(parent_pkey.public_key)
        end

        context "when properties are sorted and there is an unknown property" do
          let(:new_signature_data) { "#{author};#{guid};#{parent_guid};#{new_property};#{property}" }
          let(:author_signature) { sign_with_key(author_pkey, new_signature_data) }
          let(:parent_author_signature) { sign_with_key(parent_pkey, new_signature_data) }
          let(:entity_data) {
            {
              :guid                    => guid,
              :author                  => author,
              :property                => property,
              :parent_guid             => parent_guid,
              "new_property"           => new_property,
              :author_signature        => author_signature,
              :parent_author_signature => parent_author_signature
            }
          }
          let(:property_order) { %w(author guid parent_guid new_property property) }

          it "parses entity properties from the input data" do
            entity = Entities::SomeRelayable.from_hash(entity_data, property_order)
            expect(entity).to be_an_instance_of Entities::SomeRelayable
            expect(entity.author).to eq(author)
            expect(entity.guid).to eq(guid)
            expect(entity.parent_guid).to eq(parent_guid)
            expect(entity.property).to eq(property)
            expect(entity.author_signature).to eq(author_signature)
            expect(entity.parent_author_signature).to eq(parent_author_signature)
          end

          it "makes unknown properties available via #additional_data" do
            entity = Entities::SomeRelayable.from_hash(entity_data, property_order)
            expect(entity.additional_data).to eq("new_property" => new_property)
          end

          it "hands over the order in the data to the instance without signatures" do
            entity = Entities::SomeRelayable.from_hash(entity_data, property_order)
            expect(entity.xml_order).to eq(%w(author guid parent_guid new_property property))
          end

          it "calls a constructor of the entity of the appropriate type" do
            expect(Entities::SomeRelayable).to receive(:new).with(
              {
                author:                  author,
                guid:                    guid,
                parent_guid:             parent_guid,
                property:                property,
                author_signature:        author_signature,
                parent_author_signature: parent_author_signature,
                parent:                  remote_parent
              }.merge("new_property" => new_property),
              %w(author guid parent_guid new_property property),
              "new_property" => new_property
            ).and_call_original
            Entities::SomeRelayable.from_hash(entity_data, property_order)
          end
        end

        it "creates Entity with empty 'additional_data' if it has only known properties" do
          property_order = %w(guid author property parent_guid)

          entity_data = {
            guid:                    guid,
            author:                  author,
            property:                property,
            parent_guid:             parent_guid,
            author_signature:        sign_with_key(author_pkey, legacy_signature_data),
            parent_author_signature: sign_with_key(parent_pkey, legacy_signature_data)
          }

          entity = Entities::SomeRelayable.from_hash(entity_data, property_order)

          expect(entity).to be_an_instance_of Entities::SomeRelayable
          expect(entity.additional_data).to be_empty
        end
      end

      context "relayable signature verification feature support" do
        it "calls signatures verification on relayable unpack" do
          property_order = %w(guid author property parent_guid)
          entity_data = {
            guid:                    guid,
            author:                  author,
            property:                property,
            parent_guid:             parent_guid,
            author_signature:        "aa",
            parent_author_signature: "bb"
          }

          expect_callback(:fetch_related_entity, "Parent", parent_guid).and_return(remote_parent)
          expect_callback(:fetch_public_key, author).and_return(author_pkey.public_key)
          expect {
            Entities::SomeRelayable.from_hash(entity_data, property_order)
          }.to raise_error DiasporaFederation::Entities::Relayable::SignatureVerificationFailed
        end
      end

      context "fetch parent" do
        before do
          expect_callback(:fetch_public_key, author).and_return(author_pkey.public_key)
          expect_callback(:fetch_public_key, remote_parent.author).and_return(parent_pkey.public_key)
          expect_callback(:fetch_private_key, author).and_return(author_pkey)
          expect_callback(:fetch_private_key, remote_parent.author).and_return(parent_pkey)
        end

        let(:entity) { Entities::SomeRelayable.new(hash) }
        let(:data) {
          entity.to_h.tap {|hash|
            hash.delete(:parent)
          }
        }

        it "fetches the parent from the backend" do
          expect_callback(:fetch_related_entity, "Parent", parent_guid).and_return(remote_parent)
          expect(Federation::Fetcher).not_to receive(:fetch_public)

          new_entity = Entities::SomeRelayable.from_hash(data, entity.send(:signature_order))

          expect(new_entity.parent).to eq(remote_parent)
        end

        it "fetches the parent from remote if not found on backend" do
          expect_callback(:fetch_related_entity, "Parent", parent_guid).and_return(nil, remote_parent)
          expect(Federation::Fetcher).to receive(:fetch_public).with(author, "Parent", parent_guid)

          new_entity = Entities::SomeRelayable.from_hash(data, entity.send(:signature_order))

          expect(new_entity.parent).to eq(remote_parent)
        end
      end
    end

    describe "#sender_valid?" do
      it "allows author" do
        entity = Entities::SomeRelayable.new(hash)

        expect(entity.sender_valid?(author)).to be_truthy
      end

      it "allows parent author" do
        entity = Entities::SomeRelayable.new(hash)

        expect(entity.sender_valid?(local_parent.author)).to be_truthy
      end

      it "does not allow any random author" do
        entity = Entities::SomeRelayable.new(hash)
        invalid_author = FactoryGirl.generate(:diaspora_id)

        expect(entity.sender_valid?(invalid_author)).to be_falsey
      end
    end
  end
end
