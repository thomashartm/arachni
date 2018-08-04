require 'spec_helper'

describe Arachni::Platform::Fingerprinters::AdobeAem do
    include_examples 'fingerprinter'

    def platforms
        [:java]
    end

    context 'when the page has a /etc/design directory in a path' do
        it 'identifies it as Adobe AEM' do
            check_platforms Arachni::Page.from_data( url: 'http://stuff.com/etc/designs/we-retail/components/mainnav/menunav/publish.0.20180724073205.min.js' )
        end
    end

    context 'when the page has a granite token in the path' do
        it 'identifies it as Adobe AEM' do
            check_platforms Arachni::Page.from_data( url: 'http://stuff.com/libs/granite/csrf/token.json' )
        end
    end

    context 'when there is a Day-Servlet-Engine header' do
        it 'identifies it as Adobe AEM' do
            check_platforms Arachni::Page.from_data(
                url:     'http://stuff.com/blah',
                response: { headers: { 'Server' => 'Day-Servlet-Engine/4.1.24'  } }
            )
        end
    end

end