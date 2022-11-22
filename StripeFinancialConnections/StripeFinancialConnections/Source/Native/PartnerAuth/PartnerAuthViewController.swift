//
//  PartnerAuthViewController.swift
//  StripeFinancialConnections
//
//  Created by Krisjanis Gaidis on 7/25/22.
//

import Foundation
import UIKit
import AuthenticationServices
@_spi(STP) import StripeUICore
@_spi(STP) import StripeCore

@available(iOSApplicationExtension, unavailable)
protocol PartnerAuthViewControllerDelegate: AnyObject {
    func partnerAuthViewControllerUserDidSelectAnotherBank(_ viewController: PartnerAuthViewController)
    func partnerAuthViewControllerDidRequestToGoBack(_ viewController: PartnerAuthViewController)
    func partnerAuthViewControllerUserDidSelectEnterBankDetailsManually(_ viewController: PartnerAuthViewController)
    func partnerAuthViewController(_ viewController: PartnerAuthViewController, didReceiveTerminalError error: Error)
    func partnerAuthViewController(
        _ viewController: PartnerAuthViewController,
        didCompleteWithAuthSession authSession: FinancialConnectionsAuthSession
    )
}

@available(iOSApplicationExtension, unavailable)
final class PartnerAuthViewController: UIViewController {
    
    private let dataSource: PartnerAuthDataSource
    private var institution: FinancialConnectionsInstitution {
        return dataSource.institution
    }
    private var webAuthenticationSession: ASWebAuthenticationSession?
    private var lastHandledAuthenticationSessionReturnUrl: URL? = nil
    weak var delegate: PartnerAuthViewControllerDelegate?
    
    private lazy var establishingConnectionLoadingView: UIView = {
        let establishingConnectionLoadingView = ReusableInformationView(
            iconType: .loading,
            title: STPLocalizedString("Establishing connection", "The title of the loading screen that appears after a user selected a bank. The user is waiting for Stripe to establish a bank connection with the bank."),
            subtitle: STPLocalizedString("Please wait while we connect to your bank.", "The subtitle of the loading screen that appears after a user selected a bank. The user is waiting for Stripe to establish a bank connection with the bank.")
        )
        establishingConnectionLoadingView.isHidden = true
        return establishingConnectionLoadingView
    }()
    
    init(dataSource: PartnerAuthDataSource) {
        self.dataSource = dataSource
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .customBackgroundColor
        dataSource
            .analyticsClient
            .logPaneLoaded(pane: .partnerAuth)
        createAuthSession()
    }
    
    private func createAuthSession() {
        showEstablishingConnectionLoadingView(true)
        dataSource
            .createAuthSession()
            .observe(on: .main) { [weak self] result in
                guard let self = self else { return }
                // order is important so be careful of moving
                self.showEstablishingConnectionLoadingView(false)
                switch result {
                case .success(let authSession):
                    self.createdAuthSession(authSession)
                case .failure(let error):
                    self.showErrorView(error)
                }
            }
    }
    
    private func createdAuthSession(_ authSession: FinancialConnectionsAuthSession) {
        dataSource.recordAuthSessionEvent(
            eventName: "launched",
            authSessionId: authSession.id
        )
        
        if authSession.isOauth {
            let prepaneView = PrepaneView(
                institutionName: institution.name,
                institutionImageUrl: institution.icon?.default,
                partner: (authSession.showPartnerDisclosure ?? false) ? authSession.flow?.toPartner() : nil,
                isStripeDirect: dataSource.manifest.isStripeDirect ?? false,
                didSelectContinue: { [weak self] in
                    self?.openInstitutionAuthenticationWebView(authSession: authSession)
                }
            )
            view.addAndPinSubview(prepaneView)
            
            dataSource.recordAuthSessionEvent(
                eventName: "loaded",
                authSessionId: authSession.id
            )
        } else {
            // a legacy (non-oauth) institution will have a blank background
            // during presenting + dismissing of the Web View, so
            // add a loading spinner to fill some of the blank space
            let activityIndicator = ActivityIndicator(size: .large)
            activityIndicator.color = .textDisabled
            activityIndicator.backgroundColor = .customBackgroundColor
            activityIndicator.startAnimating()
            view.addAndPinSubview(activityIndicator)
            
            openInstitutionAuthenticationWebView(authSession: authSession)
        }
    }
    
    private func showErrorView(_ error: Error) {
        // all Partner Auth errors hide the back button
        // and all errors end up in user having to exit
        // PartnerAuth to try again
        navigationItem.hidesBackButton = true
        
        let errorView: UIView?
        if
            let error = error as? StripeError,
            case .apiError(let apiError) = error,
            let extraFields = apiError.allResponseFields["extra_fields"] as? [String:Any],
            let institutionUnavailable = extraFields["institution_unavailable"] as? Bool,
            institutionUnavailable
        {
            let institutionIconView = InstitutionIconView(size: .large, showWarning: true)
            institutionIconView.setImageUrl(institution.icon?.default)
            let primaryButtonConfiguration = ReusableInformationView.ButtonConfiguration(
                title: String.Localized.select_another_bank,
                action: { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.partnerAuthViewControllerUserDidSelectAnotherBank(self)
                }
            )
            if let expectedToBeAvailableAt = extraFields["expected_to_be_available_at"] as? TimeInterval {
                let expectedToBeAvailableDate = Date(timeIntervalSince1970: expectedToBeAvailableAt)
                let dateFormatter = DateFormatter()
                dateFormatter.timeStyle = .short
                let expectedToBeAvailableTimeString = dateFormatter.string(from: expectedToBeAvailableDate)
                errorView = ReusableInformationView(
                    iconType: .view(institutionIconView),
                    title: String(format: STPLocalizedString("%@ is undergoing maintenance", "Title of a screen that shows an error. The error indicates that the bank user selected is currently under maintenance."), institution.name),
                    subtitle: {
                        let beginningOfSubtitle: String = {
                            if IsToday(expectedToBeAvailableDate) {
                                return String(format: STPLocalizedString("Maintenance is scheduled to end at %@.", "The first part of a subtitle/description of a screen that shows an error. The error indicates that the bank user selected is currently under maintenance."), expectedToBeAvailableTimeString)
                            } else {
                                let dateFormatter = DateFormatter()
                                dateFormatter.dateStyle = .short
                                let expectedToBeAvailableDateString = dateFormatter.string(from: expectedToBeAvailableDate)
                                return String(format: STPLocalizedString("Maintenance is scheduled to end on %@ at %@.", "The first part of a subtitle/description of a screen that shows an error. The error indicates that the bank user selected is currently under maintenance."), expectedToBeAvailableDateString, expectedToBeAvailableTimeString)
                            }
                        }()
                        let endOfSubtitle: String = {
                            if dataSource.manifest.allowManualEntry {
                                return STPLocalizedString("Please enter your bank details manually or select another bank.", "The second part of a subtitle/description of a screen that shows an error. The error indicates that the bank user selected is currently under maintenance.")
                            } else {
                                return STPLocalizedString("Please select another bank or try again later.", "The second part of a subtitle/description of a screen that shows an error. The error indicates that the bank user selected is currently under maintenance.")
                            }
                        }()
                        return beginningOfSubtitle + " " + endOfSubtitle
                    }(),
                    primaryButtonConfiguration: primaryButtonConfiguration,
                    secondaryButtonConfiguration: dataSource.manifest.allowManualEntry ? ReusableInformationView.ButtonConfiguration(
                        title: String.Localized.enter_bank_details_manually,
                        action: { [weak self] in
                            guard let self = self else { return }
                            self.delegate?.partnerAuthViewControllerUserDidSelectEnterBankDetailsManually(self)
                        }
                    ) : nil
                )
                dataSource.analyticsClient.logExpectedError(
                    error,
                    errorName: "InstitutionPlannedDowntimeError",
                    pane: .partnerAuth
                )
            } else {
                errorView = ReusableInformationView(
                    iconType: .view(institutionIconView),
                    title: String(format: STPLocalizedString("%@ is currently unavailable", "Title of a screen that shows an error. The error indicates that the bank user selected is currently under maintenance."), institution.name),
                    subtitle: {
                        if dataSource.manifest.allowManualEntry {
                            return STPLocalizedString("Please enter your bank details manually or select another bank.", "The subtitle/description of a screen that shows an error. The error indicates that the bank user selected is currently under maintenance.")
                        } else {
                            return STPLocalizedString("Please select another bank or try again later.", "The subtitle/description of a screen that shows an error. The error indicates that the bank user selected is currently under maintenance.")
                        }
                    }(),
                    primaryButtonConfiguration: primaryButtonConfiguration,
                    secondaryButtonConfiguration: dataSource.manifest.allowManualEntry ? ReusableInformationView.ButtonConfiguration(
                        title: String.Localized.enter_bank_details_manually,
                        action: { [weak self] in
                            guard let self = self else { return }
                            self.delegate?.partnerAuthViewControllerUserDidSelectEnterBankDetailsManually(self)
                        }
                    ) : nil
                )
                dataSource.analyticsClient.logExpectedError(
                    error,
                    errorName: "InstitutionUnplannedDowntimeError",
                    pane: .partnerAuth
                )
            }
        } else {
            dataSource.analyticsClient.logUnexpectedError(
                error,
                errorName: "PartnerAuthError",
                pane: .partnerAuth
            )
            
            // if we didn't get specific errors back, we don't know
            // what's wrong, so show a generic error
            delegate?.partnerAuthViewController(self, didReceiveTerminalError: error)
            errorView = nil
            
            // keep showing the loading view while we transition to
            // terminal error
            showEstablishingConnectionLoadingView(true)
        }
        
        if let errorView = errorView {
            view.addAndPinSubviewToSafeArea(errorView)
        }
    }
    
    private func openInstitutionAuthenticationWebView(authSession: FinancialConnectionsAuthSession) {
        guard let urlString =  authSession.url, let url = URL(string: urlString) else {
            assertionFailure("Expected to get a URL back from authorization session.")
            return
        }
        
        lastHandledAuthenticationSessionReturnUrl = nil
        let webAuthenticationSession = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: "stripe",
            // note that `error` is NOT related to our backend
            // sending errors, it's only related to `ASWebAuthenticationSession`
            completionHandler: { [weak self] returnUrl, error in
                guard let self = self else { return }
                if self.lastHandledAuthenticationSessionReturnUrl != nil && self.lastHandledAuthenticationSessionReturnUrl == returnUrl {
                    // for unknown reason, `ASWebAuthenticationSession` can _sometimes_
                    // call the `completionHandler` twice
                    //
                    // we use `returnUrl`, instead of a `Bool`, in the case that
                    // this completion handler can sometimes return different URL's
                    return
                }
                self.lastHandledAuthenticationSessionReturnUrl = returnUrl
                if
                    let returnUrl = returnUrl,
                    returnUrl.scheme == "stripe",
                    let urlComponsents = URLComponents(url: returnUrl, resolvingAgainstBaseURL: true),
                    let status = urlComponsents.queryItems?.first(where: { $0.name == "status" })?.value
                {
                    if status == "success" {
                        self.dataSource.recordAuthSessionEvent(
                            eventName: "success",
                            authSessionId: authSession.id
                        )
                        
                        if authSession.isOauth {
                            // for OAuth flows, we need to fetch OAuth results
                            self.authorizeAuthSession(authSession)
                        } else {
                            // for legacy flows (non-OAuth), we do not need to fetch OAuth results, or call authorize
                            self.delegate?.partnerAuthViewController(self, didCompleteWithAuthSession: authSession)
                        }
                    } else if status == "failure" {
                        self.dataSource.recordAuthSessionEvent(
                            eventName: "failure",
                            authSessionId: authSession.id
                        )
                        
                        // cancel current auth session
                        self.dataSource.cancelPendingAuthSessionIfNeeded()
                        
                        // show a terminal error
                        self.showErrorView(
                            FinancialConnectionsSheetError.unknown(
                                debugDescription: "Shim returned a failure."
                            )
                        )
                    } else { // assume `status == cancel`
                        self.dataSource.recordAuthSessionEvent(
                            eventName: "cancel",
                            authSessionId: authSession.id
                        )
                        
                        // cancel current auth session
                        self.dataSource.cancelPendingAuthSessionIfNeeded()
                        
                        // whether legacy or OAuth, we always go back
                        // if we got an explicit cancel from backend
                        self.navigateBack()
                    }
                }
                // we did NOT get a `status` back from the backend,
                // so assume a "cancel"
                else {
                    // `error` is usually NOT null when user closes
                    // the browser by pressing 'Cancel' button
                    //
                    // the `error` may not always be set because of
                    // a cancellation, but we still treat it as one
                    if error != nil {
                        if authSession.isOauth {
                            // on "manual cancels" (for OAuth) we log retry event:
                            self.dataSource.recordAuthSessionEvent(
                                eventName: "retry",
                                authSessionId: authSession.id
                            )
                        } else {
                            // on "manual cancels" (for Legacy) we log cancel event:
                            self.dataSource.recordAuthSessionEvent(
                                eventName: "cancel",
                                authSessionId: authSession.id
                            )
                        }
                    }
                    
                    if let error = error {
                        self.dataSource
                            .analyticsClient
                            .logUnexpectedError(
                                error,
                                errorName: "ASWebAuthenticationSessionError",
                                pane: .partnerAuth
                            )
                    }
                    
                    // cancel current auth session because something went wrong
                    self.dataSource.cancelPendingAuthSessionIfNeeded()
                    
                    if authSession.isOauth {
                        // for OAuth institutions, we remain on the pre-pane,
                        // but create a brand new auth session
                        self.createAuthSession()
                    } else {
                        // for legacy (non-OAuth) institutions, we navigate back to InstitutionPickerViewController
                        self.navigateBack()
                    }
                }
                
                self.webAuthenticationSession = nil
        })
        self.webAuthenticationSession = webAuthenticationSession
        
        webAuthenticationSession.presentationContextProvider = self
        webAuthenticationSession.prefersEphemeralWebBrowserSession = true

        if #available(iOS 13.4, *) {
            if !webAuthenticationSession.canStart {
                // navigate back to bank picker so user can try again
                //
                // this may be an odd way to handle an issue, but trying again
                // is potentially better than forcing user to close the whole
                // auth session
                navigateBack()
                return // skip starting
            }
        }
        
        if !webAuthenticationSession.start() {
            // navigate back to bank picker so user can try again
            //
            // this may be an odd way to handle an issue, but trying again
            // is potentially better than forcing user to close the whole
            // auth session
            navigateBack()
        } else {
            // we successfully launched the secure web browser
            if authSession.isOauth {
                dataSource.recordAuthSessionEvent(
                    eventName: "oauth-launched",
                    authSessionId: authSession.id
                )
            }
        }
    }
    
    private func authorizeAuthSession(_ authSession: FinancialConnectionsAuthSession) {
        showEstablishingConnectionLoadingView(true)
        dataSource
            .authorizeAuthSession(authSession)
            .observe(on: .main) { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success(let authSession):
                    self.delegate?.partnerAuthViewController(self, didCompleteWithAuthSession: authSession)
                    
                    // hide the loading view after a delay to prevent
                    // the screen from flashing _while_ the transition
                    // to the next screen takes place
                    //
                    // note that it should be impossible to view this screen
                    // after a successful `authorizeAuthSession`, so
                    // calling `showEstablishingConnectionLoadingView(false)` is
                    // defensive programming anyway
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        self?.showEstablishingConnectionLoadingView(false)
                    }
                case .failure(let error):
                    self.showEstablishingConnectionLoadingView(false) // important to come BEFORE showing error view so we avoid showing back button
                    self.showErrorView(error)
                    assert(self.navigationItem.hidesBackButton)
                }
            }
    }
    
    private func navigateBack() {
        delegate?.partnerAuthViewControllerDidRequestToGoBack(self)
    }
    
    private func showEstablishingConnectionLoadingView(_ show: Bool) {
        if establishingConnectionLoadingView.superview == nil {
            view.addAndPinSubviewToSafeArea(establishingConnectionLoadingView)
        }
        view.bringSubviewToFront(establishingConnectionLoadingView) // bring to front in-case something else is covering it
        
        navigationItem.hidesBackButton = show
        establishingConnectionLoadingView.isHidden = !show
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

/// :nodoc:
@available(iOS 13, *)
@available(iOSApplicationExtension, unavailable)
extension PartnerAuthViewController: ASWebAuthenticationPresentationContextProviding {

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return self.view.window ?? ASPresentationAnchor()
    }
}

private func IsToday(_ comparisonDate: Date) -> Bool {
    return Calendar.current.startOfDay(for: comparisonDate) == Calendar.current.startOfDay(for: Date())
}
