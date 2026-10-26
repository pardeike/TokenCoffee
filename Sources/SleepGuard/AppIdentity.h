#ifndef TOKENCOFFEE_TEAM_ID
#define TOKENCOFFEE_TEAM_ID "W65292CD8T"
#endif

// The Mac App Store replaces the developer certificate. Its Apple signature
// seals the original team entitlement, which remains required for that branch.
#define TOKENCOFFEE_APP_REQUIREMENT CFSTR( \
    "anchor apple generic and identifier \"com.pardeike.TokenCoffee\" and (" \
    "certificate leaf[subject.OU] = \"" TOKENCOFFEE_TEAM_ID "\" or (" \
    "certificate leaf[field.1.2.840.113635.100.6.1.9] and " \
    "entitlement[\"com.apple.developer.team-identifier\"] = \"" TOKENCOFFEE_TEAM_ID "\"))")
