//! The permission bitmask of `GET auth/me` (seerr `server/lib/permissions.ts`).

/// Bit constants.
pub mod bit {
    /// Everything.
    pub const ADMIN: i64 = 2;
    /// Settings.
    pub const MANAGE_SETTINGS: i64 = 4;
    /// Users.
    pub const MANAGE_USERS: i64 = 8;
    /// Approve, decline, delete requests and media.
    pub const MANAGE_REQUESTS: i64 = 16;
    /// Request anything.
    pub const REQUEST: i64 = 32;
    /// Vote.
    pub const VOTE: i64 = 64;
    /// Requests are approved at once.
    pub const AUTO_APPROVE: i64 = 128;
    /// Films are approved at once.
    pub const AUTO_APPROVE_MOVIE: i64 = 256;
    /// Series are approved at once.
    pub const AUTO_APPROVE_TV: i64 = 512;
    /// Request 4K.
    pub const REQUEST_4K: i64 = 1024;
    /// Request 4K films.
    pub const REQUEST_4K_MOVIE: i64 = 2048;
    /// Request 4K series.
    pub const REQUEST_4K_TV: i64 = 4096;
    /// Choose server, quality profile and folder.
    pub const REQUEST_ADVANCED: i64 = 8192;
    /// See the requests of others.
    pub const REQUEST_VIEW: i64 = 16384;
    /// 4K requests are approved at once.
    pub const AUTO_APPROVE_4K: i64 = 32768;
    /// 4K films are approved at once.
    pub const AUTO_APPROVE_4K_MOVIE: i64 = 65536;
    /// 4K series are approved at once.
    pub const AUTO_APPROVE_4K_TV: i64 = 131_072;
    /// Request films.
    pub const REQUEST_MOVIE: i64 = 262_144;
    /// Request series.
    pub const REQUEST_TV: i64 = 524_288;
    /// Resolve, reopen and see all issues.
    pub const MANAGE_ISSUES: i64 = 1_048_576;
    /// See issues of others.
    pub const VIEW_ISSUES: i64 = 2_097_152;
    /// Report an issue.
    pub const CREATE_ISSUES: i64 = 4_194_304;
}

/// The permissions of one account. `ADMIN` implies every other bit.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct Perms(pub i64);

impl Perms {
    /// No permission at all.
    pub const NONE: Perms = Perms(0);

    /// True when the account is an admin.
    pub fn is_admin(self) -> bool {
        self.0 & bit::ADMIN != 0
    }

    /// True when any one of the bits is set (or the account is admin).
    pub fn has_any(self, bits: &[i64]) -> bool {
        self.is_admin() || bits.iter().any(|b| self.0 & b != 0)
    }

    /// True when the single bit is set (or the account is admin).
    pub fn has(self, bit: i64) -> bool {
        self.has_any(&[bit])
    }

    /// May ask for a film (`REQUEST` or `REQUEST_MOVIE`).
    pub fn can_request_movie(self) -> bool {
        self.has_any(&[bit::REQUEST, bit::REQUEST_MOVIE])
    }

    /// May ask for a series (`REQUEST` or `REQUEST_TV`).
    pub fn can_request_tv(self) -> bool {
        self.has_any(&[bit::REQUEST, bit::REQUEST_TV])
    }

    /// May ask for `art` (`movie` or `tv`).
    pub fn can_request(self, art: &str) -> bool {
        if art == "tv" {
            self.can_request_tv()
        } else {
            self.can_request_movie()
        }
    }

    /// May ask for the 4K version of `art`.
    pub fn can_request_4k(self, art: &str) -> bool {
        let kind = if art == "tv" {
            bit::REQUEST_4K_TV
        } else {
            bit::REQUEST_4K_MOVIE
        };
        self.has_any(&[bit::REQUEST_4K, kind])
    }

    /// May choose server, quality and folder.
    pub fn can_choose_advanced(self) -> bool {
        self.has_any(&[bit::REQUEST_ADVANCED, bit::MANAGE_REQUESTS])
    }

    /// May approve, decline, withdraw any request and delete media.
    pub fn can_manage_requests(self) -> bool {
        self.has(bit::MANAGE_REQUESTS)
    }

    /// Requests of this kind are approved at once.
    pub fn auto_approves(self, art: &str, is4k: bool) -> bool {
        let tv = art == "tv";
        let bits: [i64; 2] = match (is4k, tv) {
            (false, false) => [bit::AUTO_APPROVE, bit::AUTO_APPROVE_MOVIE],
            (false, true) => [bit::AUTO_APPROVE, bit::AUTO_APPROVE_TV],
            (true, false) => [bit::AUTO_APPROVE_4K, bit::AUTO_APPROVE_4K_MOVIE],
            (true, true) => [bit::AUTO_APPROVE_4K, bit::AUTO_APPROVE_4K_TV],
        };
        self.has_any(&bits)
    }

    /// May report a problem.
    pub fn can_create_issues(self) -> bool {
        self.has_any(&[bit::CREATE_ISSUES, bit::MANAGE_ISSUES])
    }

    /// May resolve and reopen issues (and sees everyone's).
    pub fn can_manage_issues(self) -> bool {
        self.has(bit::MANAGE_ISSUES)
    }

    /// May open the issue list.
    pub fn can_view_issues(self) -> bool {
        self.has_any(&[bit::VIEW_ISSUES, bit::MANAGE_ISSUES])
    }

    /// May see the requests of other users.
    pub fn can_view_all_requests(self) -> bool {
        self.has_any(&[bit::REQUEST_VIEW, bit::MANAGE_REQUESTS])
    }
}
