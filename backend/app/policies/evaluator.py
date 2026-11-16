"""
Policy evaluation engine.

Evaluates ONE target against ONE policy (or the fail-safe default, when
no policy is assigned or the assigned one is disabled) and returns a
structured, explainable decision. Deliberately does NOT calculate risk —
see app/risk/engine.py and app/services/access_decision.py, which combine
this with a risk evaluation. Keeping the two separate means either can
be tuned/tested without touching the other.
"""

from dataclasses import dataclass
from datetime import datetime, timezone
from typing import List, Optional, Union
from uuid import UUID

from app.core.business_hours import is_allowed_day, is_business_hours
from app.models.application import Application
from app.models.asset import Asset
from app.models.policy import Policy
from app.models.user import User

try:
    import securepam_policy_engine
    from securepam_policy_engine.models import AccessContext, Decision, ReasonCode
    HAS_STANDALONE_POLICY_ENGINE = True
except ImportError:
    securepam_policy_engine = None
    HAS_STANDALONE_POLICY_ENGINE = False

# Fail-safe stance when NO policy governs this target (none assigned, or
# the assigned one is disabled): more scrutiny, not less. Still `allowed`
# (the request can proceed to the approval queue) rather than an outright
# deny, since most registered Assets/Applications won't have an explicit
# Policy assigned yet and that must not make them completely unusable.
DEFAULT_MAX_DURATION_MINUTES = 30


@dataclass(frozen=True)
class PolicyDecision:
    allowed: bool
    policy_id: Optional[UUID]
    policy_name: Optional[str]
    approval_required: bool
    mfa_required: bool
    jit_required: bool
    recording_required: bool
    max_duration: int
    # Whether the policy permits skipping human approval for a LOW/MEDIUM
    # risk request. Distinct from `approval_required` (the policy's own
    # baseline) — app/services/access_decision.py's decision matrix needs
    # both: "does the policy demand approval" AND "is auto-approval even
    # on the table". False in the no-policy/disabled-policy fail-safe case.
    auto_approve: bool
    reasons: List[str]

    def to_dict(self) -> dict:
        return {
            "allowed": self.allowed,
            "policy_id": str(self.policy_id) if self.policy_id else None,
            "policy_name": self.policy_name,
            "approval_required": self.approval_required,
            "mfa_required": self.mfa_required,
            "jit_required": self.jit_required,
            "recording_required": self.recording_required,
            "max_duration": self.max_duration,
            "auto_approve": self.auto_approve,
            "reasons": self.reasons,
        }


class PolicyEvaluator:
    def evaluate_access(
        self,
        *,
        user: User,
        target: Union[Asset, Application],
        policy: Optional[Policy],
        protocol: str,
        requested_duration: int,
        now: Optional[datetime] = None,
    ) -> PolicyDecision:
        now = now or datetime.now(timezone.utc)

        if policy is None or not policy.enabled:
            reason = (
                "No policy is assigned to this target"
                if policy is None
                else f"Assigned policy '{policy.name}' is disabled"
            )
            return PolicyDecision(
                allowed=True,
                policy_id=None,
                policy_name=None,
                approval_required=True,
                mfa_required=True,
                jit_required=True,
                recording_required=False,
                auto_approve=False,
                max_duration=min(requested_duration, DEFAULT_MAX_DURATION_MINUTES),
                reasons=[f"{reason} — applying conservative default controls (approval and MFA required)"],
            )

        reasons: List[str] = [f"Evaluated against policy '{policy.name}'"]
        allowed = True

        if policy.deny_access:
            allowed = False
            reasons.append("Policy explicitly denies access for any request matching it")

        user_role_names = {ur.role.name for ur in user.roles if ur.role}
        if policy.allowed_roles and not (user_role_names & set(policy.allowed_roles)):
            allowed = False
            reasons.append(
                f"Requester's role(s) ({', '.join(sorted(user_role_names)) or 'none'}) "
                f"not in policy's allowed_roles ({', '.join(policy.allowed_roles)})"
            )

        target_asset_type = getattr(target, "asset_type", None)
        if policy.allowed_asset_types and target_asset_type and target_asset_type not in policy.allowed_asset_types:
            allowed = False
            reasons.append(
                f"Target asset type ({target_asset_type}) not in policy's allowed_asset_types "
                f"({', '.join(policy.allowed_asset_types)})"
            )

        if policy.allowed_environments and target.environment not in policy.allowed_environments:
            allowed = False
            reasons.append(
                f"Target environment ({target.environment}) not in policy's allowed_environments "
                f"({', '.join(policy.allowed_environments)})"
            )

        if policy.allowed_protocols and protocol not in policy.allowed_protocols:
            allowed = False
            reasons.append(
                f"Protocol ({protocol}) not in policy's allowed_protocols ({', '.join(policy.allowed_protocols)})"
            )

        if policy.business_hours_only and not is_business_hours(now):
            allowed = False
            reasons.append(
                "Policy restricts access to business hours (09:00-17:00 UTC, Mon-Fri) "
                "and this request falls outside that window"
            )

        if policy.allowed_days and not is_allowed_day(now, policy.allowed_days):
            allowed = False
            reasons.append(
                f"Policy restricts access to {', '.join(policy.allowed_days)} and today is not one of those days"
            )

        # Clamp, never reject, on duration alone — the spec's own JIT
        # example (requested 120m, policy max 30m -> grant 30m) is exactly
        # this: an over-long request is honored at the policy's ceiling,
        # not turned into a denial.
        max_duration = min(requested_duration, policy.max_session_duration)
        if max_duration < requested_duration:
            reasons.append(
                f"Requested duration ({requested_duration}m) will be capped at the policy maximum "
                f"({policy.max_session_duration}m)"
            )

        if allowed:
            reasons.append("Policy permits this request")

        return PolicyDecision(
            allowed=allowed,
            policy_id=policy.id,
            policy_name=policy.name,
            approval_required=policy.require_approval,
            mfa_required=policy.require_mfa,
            jit_required=policy.jit_required,
            recording_required=policy.require_recording,
            max_duration=max_duration,
            auto_approve=policy.auto_approve,
            reasons=reasons,
        )

    @staticmethod
    def to_engine_context(
        user: User,
        target: Union[Asset, Application],
        protocol: str,
        requested_duration: int,
        request_id: Optional[str] = None,
        now: Optional[datetime] = None,
        risk_score: Optional[int] = None,
    ):
        """Constructs a securepam_policy_engine.AccessContext from local ORM models."""
        if not HAS_STANDALONE_POLICY_ENGINE:
            return None
        roles = sorted({ur.role.name for ur in user.roles if ur.role})
        primary_role = roles[0] if roles else "operator"
        extra_roles = tuple(roles[1:]) if len(roles) > 1 else ()
        now_utc = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
        return AccessContext(
            request_id=str(request_id or user.id),
            user_id=str(user.id),
            role=primary_role,
            extra_roles=extra_roles,
            target_id=str(target.id),
            target_registered=True,
            environment=getattr(target, "environment", "production"),
            protocol=protocol,
            requested_duration_minutes=requested_duration,
            now=now_utc,
            risk_score=risk_score,
            criticality=getattr(target, "criticality", None),
        )
