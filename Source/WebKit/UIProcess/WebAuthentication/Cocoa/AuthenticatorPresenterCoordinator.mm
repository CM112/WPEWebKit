/*
 * Copyright (C) 2020 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "AuthenticatorPresenterCoordinator.h"

#if ENABLE(WEB_AUTHN)

#import "AuthenticatorManager.h"
#import "WKASCAuthorizationPresenterDelegate.h"
#import <wtf/BlockPtr.h>

#import "AuthenticationServicesCoreSoftLink.h"

namespace WebKit {
using namespace WebCore;

AuthenticatorPresenterCoordinator::AuthenticatorPresenterCoordinator(const AuthenticatorManager& manager, const String& rpId, const TransportSet& transports, ClientDataType type)
    : m_manager(makeWeakPtr(manager))
{
#if HAVE(ASC_AUTH_UI)
    m_context = adoptNS([allocASCAuthorizationPresentationContextInstance() initWithRequestContext:nullptr appIdentifier:nullptr]);
    if ([getASCAuthorizationPresentationContextClass() instancesRespondToSelector:@selector(setServiceName:)])
        [m_context setServiceName:rpId];

    switch (type) {
    case ClientDataType::Create:
        if (transports.contains(AuthenticatorTransport::Internal))
            [m_context addLoginChoice:adoptNS([allocASCPlatformPublicKeyCredentialLoginChoiceInstance() initRegistrationChoice]).get()];
        if (transports.contains(AuthenticatorTransport::Usb) || transports.contains(AuthenticatorTransport::Nfc))
            [m_context addLoginChoice:adoptNS([allocASCSecurityKeyPublicKeyCredentialLoginChoiceInstance() initRegistrationChoice]).get()];
        break;
    case ClientDataType::Get:
        if (transports.contains(AuthenticatorTransport::Usb) || transports.contains(AuthenticatorTransport::Nfc))
            [m_context addLoginChoice:adoptNS([allocASCSecurityKeyPublicKeyCredentialLoginChoiceInstance() initAssertionPlaceholderChoice]).get()];
        break;
    default:
        ASSERT_NOT_REACHED();
    }

    m_presenterDelegate = [[WKASCAuthorizationPresenterDelegate alloc] initWithCoordinator:*this];
    m_presenter = [allocASCAuthorizationPresenterInstance() init];
    [m_presenter setDelegate:m_presenterDelegate.get()];

    auto completionHandler = makeBlockPtr([manager = m_manager] (id<ASCCredentialProtocol> credential, NSError *error) mutable {
        ASSERT(!RunLoop::isMain());
        if (credential || !error)
            return;

        LOG_ERROR("Couldn't complete the authenticator presentation context: %@", error);
        // This block can be executed in another thread.
        RunLoop::main().dispatch([manager] () mutable {
            if (manager)
                manager->cancel();
        });
    });
    [m_presenter presentAuthorizationWithContext:m_context.get() completionHandler:completionHandler.get()];
#endif // HAVE(ASC_AUTH_UI)
}

AuthenticatorPresenterCoordinator::~AuthenticatorPresenterCoordinator()
{
    if (m_laContextHandler)
        m_laContextHandler(nullptr);
    if (m_responseHandler)
        m_responseHandler(nullptr);
    if (m_pinHandler)
        m_pinHandler(String());
}

void AuthenticatorPresenterCoordinator::updatePresenter(WebAuthenticationStatus status)
{
#if HAVE(ASC_AUTH_UI)
    switch (status) {
    case WebAuthenticationStatus::PinBlocked: {
        auto error = adoptNS([[NSError alloc] initWithDomain:ASCAuthorizationErrorDomain code:ASCAuthorizationErrorPINRequired userInfo:@{ ASCPINValidationResultKey: @(ASCPINValidationResultPINBlocked) }]);
        m_credentialRequestHandler(nil, error.get());
        break;
    }
    case WebAuthenticationStatus::PinAuthBlocked: {
        auto error = adoptNS([[NSError alloc] initWithDomain:ASCAuthorizationErrorDomain code:ASCAuthorizationErrorPINRequired userInfo:@{ ASCPINValidationResultKey: @(ASCPINValidationResultPINAuthBlocked) }]);
        m_credentialRequestHandler(nil, error.get());
        break;
    }
    case WebAuthenticationStatus::PinInvalid: {
        auto error = adoptNS([[NSError alloc] initWithDomain:ASCAuthorizationErrorDomain code:ASCAuthorizationErrorPINRequired userInfo:@{ ASCPINValidationResultKey: @(ASCPINValidationResultPINInvalid) }]);
        m_credentialRequestHandler(nil, error.get());
        break;
    }
    case WebAuthenticationStatus::MultipleNFCTagsPresent: {
        auto error = adoptNS([[NSError alloc] initWithDomain:ASCAuthorizationErrorDomain code:ASCAuthorizationErrorMultipleNFCTagsPresent userInfo:nil]);
        [m_presenter updateInterfaceForUserVisibleError:error.get()];
        break;
    }
    case WebAuthenticationStatus::NoCredentialsFound:
    case WebAuthenticationStatus::LANoCredential: {
        auto error = adoptNS([[NSError alloc] initWithDomain:ASCAuthorizationErrorDomain code:ASCAuthorizationErrorNoCredentialsFound userInfo:nil]);
        [m_presenter updateInterfaceForUserVisibleError:error.get()];
        break;
    }
    case WebAuthenticationStatus::LAError: {
        auto error = adoptNS([[NSError alloc] initWithDomain:ASCAuthorizationErrorDomain code:ASCAuthorizationErrorLAError userInfo:nil]);
        [m_presenter updateInterfaceForUserVisibleError:error.get()];
        break;
    }
    case WebAuthenticationStatus::LAExcludeCredentialsMatched: {
        auto error = adoptNS([[NSError alloc] initWithDomain:ASCAuthorizationErrorDomain code:ASCAuthorizationErrorLAExcludeCredentialsMatched userInfo:nil]);
        [m_presenter updateInterfaceForUserVisibleError:error.get()];
        break;
    }
    default:
        ASSERT_NOT_REACHED();
        break;
    }
#endif // HAVE(ASC_AUTH_UI)
}

void AuthenticatorPresenterCoordinator::requestPin(uint64_t, CompletionHandler<void(const String&)>&& completionHandler)
{
#if HAVE(ASC_AUTH_UI)
    m_pinHandler = WTFMove(completionHandler);
    [m_presenter presentPINEntryInterface];
#endif // HAVE(ASC_AUTH_UI)
}

void AuthenticatorPresenterCoordinator::selectAssertionResponse(Vector<Ref<AuthenticatorAssertionResponse>>&& responses, WebAuthenticationSource source, CompletionHandler<void(AuthenticatorAssertionResponse*)>&& completionHandler)
{
#if HAVE(ASC_AUTH_UI)
    if (m_responseHandler)
        m_responseHandler(nullptr);
    m_responseHandler = WTFMove(completionHandler);

    if (source == WebAuthenticationSource::External) {
        auto loginChoices = adoptNS([[NSMutableArray alloc] init]);

        for (auto& response : responses) {
            RetainPtr<NSData> userHandle;
            if (response->userHandle())
                userHandle = adoptNS([[NSData alloc] initWithBytes:response->userHandle()->data() length:response->userHandle()->byteLength()]);

            auto loginChoice = adoptNS([allocASCSecurityKeyPublicKeyCredentialLoginChoiceInstance() initWithName:response->name() displayName:response->displayName() userHandle:userHandle.get()]);
            [loginChoices addObject:loginChoice.get()];

            m_credentials.add((ASCLoginChoiceProtocol *)loginChoice.get(), WTFMove(response));
        }

        [m_presenter updateInterfaceWithLoginChoices:loginChoices.get()];
        return;
    }

    if (source == WebAuthenticationSource::Local) {
        auto loginChoices = adoptNS([[NSMutableArray alloc] init]);

        for (auto& response : responses) {
            RetainPtr<NSData> userHandle;
            if (response->userHandle())
                userHandle = adoptNS([[NSData alloc] initWithBytes:response->userHandle()->data() length:response->userHandle()->byteLength()]);

            auto loginChoice = adoptNS([allocASCPlatformPublicKeyCredentialLoginChoiceInstance() initWithName:response->name() displayName:response->displayName() userHandle:userHandle.get()]);
            [loginChoices addObject:loginChoice.get()];

            m_credentials.add((ASCLoginChoiceProtocol *)loginChoice.get(), WTFMove(response));
        }

        [loginChoices addObjectsFromArray:[m_context loginChoices]]; // Adds the security key option if exists.
        [m_presenter updateInterfaceWithLoginChoices:loginChoices.get()];
        return;
    }
#endif // HAVE(ASC_AUTH_UI)
}

void AuthenticatorPresenterCoordinator::requestLAContextForUserVerification(CompletionHandler<void(LAContext *)>&& completionHandler)
{
    if (m_laContext) {
        completionHandler(m_laContext.get());
        return;
    }

    m_laContextHandler = WTFMove(completionHandler);
}

void AuthenticatorPresenterCoordinator::dimissPresenter(WebAuthenticationResult result)
{
#if HAVE(ASC_AUTH_UI)
    if (result == WebAuthenticationResult::Succeeded && m_credentialRequestHandler) {
        // FIXME(219767): Replace the ASCAppleIDCredential with the upcoming WebAuthn credentials one.
        // This is just a place holder to tell the UI that the ceremony succeeds.
        m_credentialRequestHandler(adoptNS([WebKit::allocASCAppleIDCredentialInstance() initWithUser:@"" identityToken:adoptNS([[NSData alloc] init]).get()]).get(), nil);
        return;
    }

    [m_presenter dismissWithError:nil];
#endif // HAVE(ASC_AUTH_UI)
}

void AuthenticatorPresenterCoordinator::setLAContext(LAContext *context)
{
    if (m_laContextHandler) {
        m_laContextHandler(context);
        return;
    }

    m_laContext = context;
}

void AuthenticatorPresenterCoordinator::didSelectAssertionResponse(ASCLoginChoiceProtocol *loginChoice, LAContext *context)
{
    auto response = m_credentials.take(loginChoice);
    if (!response)
        return;

    if (context)
        response->setLAContext(context);

    m_responseHandler(response.get());
}

void AuthenticatorPresenterCoordinator::setPin(const String& pin)
{
    m_pinHandler(pin);
}

} // namespace WebKit

#endif // ENABLE(WEB_AUTHN)
