import { ethers, upgrades } from "hardhat";
import { expect } from "chai";
import { loadFixture, time } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { ClawPactTipJar } from "../typechain-types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

// ========================= Helpers =========================

const USDC_DECIMALS = 6;
const usdc = (n: number) => ethers.parseUnits(n.toString(), USDC_DECIMALS);

const TIP_TYPEHASH = ethers.keccak256(
    ethers.toUtf8Bytes(
        "Tip(address tipper,address recipient,uint256 amount,string postId,uint256 nonce,uint256 expiredAt)"
    )
);

// ========================= Fixtures =========================

async function deployFixture() {
    const [owner, platformSigner, treasury, tipper, recipient, other] =
        await ethers.getSigners();

    // Deploy mock USDC
    const MockERC20 = await ethers.getContractFactory("MockUSDC");
    const mockUsdc = await MockERC20.deploy();
    await mockUsdc.waitForDeployment();

    // Deploy TipJar via UUPS proxy
    const TipJarFactory = await ethers.getContractFactory("ClawPactTipJar");
    const tipJar = (await upgrades.deployProxy(
        TipJarFactory,
        [
            await mockUsdc.getAddress(),
            platformSigner.address,
            treasury.address,
            owner.address,
        ],
        { kind: "uups", unsafeAllow: ["constructor"] }
    )) as unknown as ClawPactTipJar;

    // Mint USDC to tipper and approve TipJar
    await mockUsdc.mint(tipper.address, usdc(100_000));
    await mockUsdc
        .connect(tipper)
        .approve(await tipJar.getAddress(), ethers.MaxUint256);

    // Also mint to "other" for multi-user tests
    await mockUsdc.mint(other.address, usdc(100_000));
    await mockUsdc
        .connect(other)
        .approve(await tipJar.getAddress(), ethers.MaxUint256);

    return { tipJar, mockUsdc, owner, platformSigner, treasury, tipper, recipient, other };
}

// Helper to generate platform EIP-712 signature
async function signTip(
    tipJar: ClawPactTipJar,
    signer: SignerWithAddress,
    tipper: string,
    recipient: string,
    amount: bigint,
    postId: string,
    nonce: bigint,
    expiredAt: bigint
): Promise<string> {
    const domain = {
        name: "ClawPactTipJar",
        version: "1",
        chainId: (await ethers.provider.getNetwork()).chainId,
        verifyingContract: await tipJar.getAddress(),
    };
    const types = {
        Tip: [
            { name: "tipper", type: "address" },
            { name: "recipient", type: "address" },
            { name: "amount", type: "uint256" },
            { name: "postId", type: "string" },
            { name: "nonce", type: "uint256" },
            { name: "expiredAt", type: "uint256" },
        ],
    };
    const value = {
        tipper,
        recipient,
        amount,
        postId,
        nonce,
        expiredAt,
    };
    return signer.signTypedData(domain, types, value);
}

// ========================= Tests =========================

describe("ClawPactTipJar", function () {
    // ── Initialization ──

    describe("Initialization", function () {
        it("should initialize with correct values", async function () {
            const { tipJar, treasury, platformSigner } = await loadFixture(deployFixture);
            expect(await tipJar.platformFeeBps()).to.equal(500);
            expect(await tipJar.maxTipAmount()).to.equal(usdc(1_000));
            expect(await tipJar.dailyTipCap()).to.equal(usdc(5_000));
            expect(await tipJar.platformSigner()).to.equal(platformSigner.address);
            expect(await tipJar.treasury()).to.equal(treasury.address);
            expect(await tipJar.paused()).to.equal(false);
        });

        it("should not allow double initialization", async function () {
            const { tipJar, platformSigner, treasury, owner } =
                await loadFixture(deployFixture);
            await expect(
                tipJar.initialize(
                    ethers.ZeroAddress,
                    platformSigner.address,
                    treasury.address,
                    owner.address
                )
            ).to.be.reverted;
        });
    });

    // ── Core tipping ──

    describe("Tipping", function () {
        it("should successfully tip with valid signature", async function () {
            const { tipJar, mockUsdc, platformSigner, treasury, tipper, recipient } =
                await loadFixture(deployFixture);

            const amount = usdc(100);
            const nonce = 1n;
            const expiredAt = BigInt(Math.floor(Date.now() / 1000) + 3600);
            const postId = "post-uuid-001";

            const sig = await signTip(
                tipJar, platformSigner,
                tipper.address, recipient.address,
                amount, postId, nonce, expiredAt
            );

            const tipperBefore = await mockUsdc.balanceOf(tipper.address);
            const recipientBefore = await mockUsdc.balanceOf(recipient.address);
            const treasuryBefore = await mockUsdc.balanceOf(treasury.address);

            await expect(
                tipJar.connect(tipper).tip(
                    recipient.address, amount, postId, nonce, expiredAt, sig
                )
            )
                .to.emit(tipJar, "TipSent")
                .withArgs(tipper.address, recipient.address, amount, usdc(5), postId);

            // Verify balances: 100 USDC total, 95 to recipient, 5 to treasury
            expect(await mockUsdc.balanceOf(tipper.address)).to.equal(
                tipperBefore - amount
            );
            expect(await mockUsdc.balanceOf(recipient.address)).to.equal(
                recipientBefore + usdc(95)
            );
            expect(await mockUsdc.balanceOf(treasury.address)).to.equal(
                treasuryBefore + usdc(5)
            );
        });

        it("should update TipStats correctly", async function () {
            const { tipJar, platformSigner, tipper, recipient } =
                await loadFixture(deployFixture);

            const amount = usdc(200);
            const nonce = 1n;
            const expiredAt = BigInt(Math.floor(Date.now() / 1000) + 3600);

            const sig = await signTip(
                tipJar, platformSigner,
                tipper.address, recipient.address,
                amount, "p1", nonce, expiredAt
            );

            await tipJar.connect(tipper).tip(
                recipient.address, amount, "p1", nonce, expiredAt, sig
            );

            // Tipper stats
            const tipperStats = await tipJar.tipStats(tipper.address);
            expect(tipperStats.totalSent).to.equal(usdc(200));
            expect(tipperStats.totalFeesPaid).to.equal(usdc(10)); // 5%
            expect(tipperStats.tipsSentCount).to.equal(1);

            // Recipient stats
            const recipientStats = await tipJar.tipStats(recipient.address);
            expect(recipientStats.totalReceived).to.equal(usdc(190));
            expect(recipientStats.tipsReceivedCount).to.equal(1);
        });

        it("should accumulate stats across multiple tips", async function () {
            const { tipJar, platformSigner, tipper, recipient } =
                await loadFixture(deployFixture);

            const expiredAt = BigInt(Math.floor(Date.now() / 1000) + 3600);

            for (let i = 1; i <= 3; i++) {
                const sig = await signTip(
                    tipJar, platformSigner,
                    tipper.address, recipient.address,
                    usdc(10), `p${i}`, BigInt(i), expiredAt
                );
                await tipJar.connect(tipper).tip(
                    recipient.address, usdc(10), `p${i}`, BigInt(i), expiredAt, sig
                );
            }

            const stats = await tipJar.tipStats(tipper.address);
            expect(stats.totalSent).to.equal(usdc(30));
            expect(stats.tipsSentCount).to.equal(3);
        });
    });

    // ── Guards ──

    describe("Guards", function () {
        it("should reject self-tipping", async function () {
            const { tipJar, platformSigner, tipper } =
                await loadFixture(deployFixture);

            const sig = await signTip(
                tipJar, platformSigner,
                tipper.address, tipper.address,
                usdc(10), "p1", 1n, BigInt(Math.floor(Date.now() / 1000) + 3600)
            );

            await expect(
                tipJar.connect(tipper).tip(
                    tipper.address, usdc(10), "p1", 1n,
                    BigInt(Math.floor(Date.now() / 1000) + 3600), sig
                )
            ).to.be.revertedWithCustomError(tipJar, "SelfTipNotAllowed");
        });

        it("should reject expired signature", async function () {
            const { tipJar, platformSigner, tipper, recipient } =
                await loadFixture(deployFixture);

            const pastTime = BigInt(Math.floor(Date.now() / 1000) - 3600);
            const sig = await signTip(
                tipJar, platformSigner,
                tipper.address, recipient.address,
                usdc(10), "p1", 1n, pastTime
            );

            await expect(
                tipJar.connect(tipper).tip(
                    recipient.address, usdc(10), "p1", 1n, pastTime, sig
                )
            ).to.be.revertedWithCustomError(tipJar, "SignatureExpired");
        });

        it("should reject replayed nonce", async function () {
            const { tipJar, platformSigner, tipper, recipient } =
                await loadFixture(deployFixture);

            const expiredAt = BigInt(Math.floor(Date.now() / 1000) + 3600);
            const sig = await signTip(
                tipJar, platformSigner,
                tipper.address, recipient.address,
                usdc(10), "p1", 1n, expiredAt
            );

            // First tip succeeds
            await tipJar.connect(tipper).tip(
                recipient.address, usdc(10), "p1", 1n, expiredAt, sig
            );

            // Replay with same nonce fails
            await expect(
                tipJar.connect(tipper).tip(
                    recipient.address, usdc(10), "p1", 1n, expiredAt, sig
                )
            ).to.be.revertedWithCustomError(tipJar, "NonceAlreadyUsed");
        });

        it("should reject invalid signature (wrong signer)", async function () {
            const { tipJar, tipper, recipient, other } =
                await loadFixture(deployFixture);

            // `other` is NOT the platformSigner
            const expiredAt = BigInt(Math.floor(Date.now() / 1000) + 3600);
            const sig = await signTip(
                tipJar, other,
                tipper.address, recipient.address,
                usdc(10), "p1", 1n, expiredAt
            );

            await expect(
                tipJar.connect(tipper).tip(
                    recipient.address, usdc(10), "p1", 1n, expiredAt, sig
                )
            ).to.be.revertedWithCustomError(tipJar, "InvalidSignature");
        });

        it("should reject tip below minimum", async function () {
            const { tipJar, platformSigner, tipper, recipient } =
                await loadFixture(deployFixture);

            const expiredAt = BigInt(Math.floor(Date.now() / 1000) + 3600);
            const tooSmall = 9_999n; // below 10000 (0.01 USDC)
            const sig = await signTip(
                tipJar, platformSigner,
                tipper.address, recipient.address,
                tooSmall, "p1", 1n, expiredAt
            );

            await expect(
                tipJar.connect(tipper).tip(
                    recipient.address, tooSmall, "p1", 1n, expiredAt, sig
                )
            ).to.be.revertedWithCustomError(tipJar, "BelowMinTip");
        });

        it("should reject tip above max tip amount", async function () {
            const { tipJar, platformSigner, tipper, recipient } =
                await loadFixture(deployFixture);

            const expiredAt = BigInt(Math.floor(Date.now() / 1000) + 3600);
            const tooLarge = usdc(1_001); // max is 1000
            const sig = await signTip(
                tipJar, platformSigner,
                tipper.address, recipient.address,
                tooLarge, "p1", 1n, expiredAt
            );

            await expect(
                tipJar.connect(tipper).tip(
                    recipient.address, tooLarge, "p1", 1n, expiredAt, sig
                )
            ).to.be.revertedWithCustomError(tipJar, "ExceedsMaxTip");
        });

        it("should reject when paused", async function () {
            const { tipJar, owner, platformSigner, tipper, recipient } =
                await loadFixture(deployFixture);

            await tipJar.connect(owner).setPaused(true);

            const expiredAt = BigInt(Math.floor(Date.now() / 1000) + 3600);
            const sig = await signTip(
                tipJar, platformSigner,
                tipper.address, recipient.address,
                usdc(10), "p1", 1n, expiredAt
            );

            await expect(
                tipJar.connect(tipper).tip(
                    recipient.address, usdc(10), "p1", 1n, expiredAt, sig
                )
            ).to.be.revertedWithCustomError(tipJar, "TippingPausedError");
        });
    });

    // ── Daily cap ──

    describe("Daily Cap", function () {
        it("should enforce daily tip cap", async function () {
            const { tipJar, owner, platformSigner, tipper, recipient } =
                await loadFixture(deployFixture);

            // Set a low daily cap for testing
            await tipJar.connect(owner).setDailyTipCap(usdc(50));

            const expiredAt = BigInt(Math.floor(Date.now() / 1000) + 3600);

            // Tip 40 USDC — should succeed
            const sig1 = await signTip(
                tipJar, platformSigner,
                tipper.address, recipient.address,
                usdc(40), "p1", 1n, expiredAt
            );
            await tipJar.connect(tipper).tip(
                recipient.address, usdc(40), "p1", 1n, expiredAt, sig1
            );

            // Tip 20 USDC — should fail (40 + 20 = 60 > 50 cap)
            const sig2 = await signTip(
                tipJar, platformSigner,
                tipper.address, recipient.address,
                usdc(20), "p2", 2n, expiredAt
            );
            await expect(
                tipJar.connect(tipper).tip(
                    recipient.address, usdc(20), "p2", 2n, expiredAt, sig2
                )
            ).to.be.revertedWithCustomError(tipJar, "ExceedsDailyCap");
        });

        it("should report daily spent amount", async function () {
            const { tipJar, platformSigner, tipper, recipient } =
                await loadFixture(deployFixture);

            const expiredAt = BigInt(Math.floor(Date.now() / 1000) + 3600);
            const sig = await signTip(
                tipJar, platformSigner,
                tipper.address, recipient.address,
                usdc(50), "p1", 1n, expiredAt
            );
            await tipJar.connect(tipper).tip(
                recipient.address, usdc(50), "p1", 1n, expiredAt, sig
            );

            expect(await tipJar.dailyTipSpent(tipper.address)).to.equal(usdc(50));
        });

        it("should allow unlimited tipping when daily cap is 0", async function () {
            const { tipJar, owner, platformSigner, tipper, recipient } =
                await loadFixture(deployFixture);

            // Remove daily cap
            await tipJar.connect(owner).setDailyTipCap(0);
            // Also raise max tip
            await tipJar.connect(owner).setMaxTipAmount(0);

            const expiredAt = BigInt(Math.floor(Date.now() / 1000) + 3600);
            const sig = await signTip(
                tipJar, platformSigner,
                tipper.address, recipient.address,
                usdc(10_000), "p1", 1n, expiredAt
            );
            await tipJar.connect(tipper).tip(
                recipient.address, usdc(10_000), "p1", 1n, expiredAt, sig
            );

            expect(await tipJar.dailyTipSpent(tipper.address)).to.equal(0); // not tracked when cap=0
        });
    });

    // ── Admin functions ──

    describe("Admin", function () {
        it("should allow owner to update fee", async function () {
            const { tipJar, owner } = await loadFixture(deployFixture);
            await expect(tipJar.connect(owner).setPlatformFeeBps(300))
                .to.emit(tipJar, "PlatformFeeUpdated")
                .withArgs(500, 300);
            expect(await tipJar.platformFeeBps()).to.equal(300);
        });

        it("should reject fee above 10%", async function () {
            const { tipJar, owner } = await loadFixture(deployFixture);
            await expect(
                tipJar.connect(owner).setPlatformFeeBps(1001)
            ).to.be.revertedWithCustomError(tipJar, "FeeTooHigh");
        });

        it("should reject non-owner admin calls", async function () {
            const { tipJar, other } = await loadFixture(deployFixture);
            await expect(
                tipJar.connect(other).setPlatformFeeBps(300)
            ).to.be.reverted;
        });

        it("should allow owner to update signer", async function () {
            const { tipJar, owner, other } = await loadFixture(deployFixture);
            await expect(tipJar.connect(owner).setPlatformSigner(other.address))
                .to.emit(tipJar, "PlatformSignerUpdated");
        });

        it("should reject zero-address signer", async function () {
            const { tipJar, owner } = await loadFixture(deployFixture);
            await expect(
                tipJar.connect(owner).setPlatformSigner(ethers.ZeroAddress)
            ).to.be.revertedWithCustomError(tipJar, "ZeroAddress");
        });
    });

    // ── Edge cases ──

    describe("Edge Cases", function () {
        it("should handle 0% fee correctly", async function () {
            const { tipJar, mockUsdc, owner, platformSigner, tipper, recipient, treasury } =
                await loadFixture(deployFixture);

            await tipJar.connect(owner).setPlatformFeeBps(0);

            const expiredAt = BigInt(Math.floor(Date.now() / 1000) + 3600);
            const sig = await signTip(
                tipJar, platformSigner,
                tipper.address, recipient.address,
                usdc(100), "p1", 1n, expiredAt
            );

            const treasuryBefore = await mockUsdc.balanceOf(treasury.address);

            await tipJar.connect(tipper).tip(
                recipient.address, usdc(100), "p1", 1n, expiredAt, sig
            );

            // Treasury balance unchanged (0 fee)
            expect(await mockUsdc.balanceOf(treasury.address)).to.equal(treasuryBefore);
        });

        it("should isolate nonces per user", async function () {
            const { tipJar, platformSigner, tipper, recipient, other } =
                await loadFixture(deployFixture);

            const expiredAt = BigInt(Math.floor(Date.now() / 1000) + 3600);

            // tipper uses nonce 1
            const sig1 = await signTip(
                tipJar, platformSigner,
                tipper.address, recipient.address,
                usdc(10), "p1", 1n, expiredAt
            );
            await tipJar.connect(tipper).tip(
                recipient.address, usdc(10), "p1", 1n, expiredAt, sig1
            );

            // other can also use nonce 1 (isolated per user)
            const sig2 = await signTip(
                tipJar, platformSigner,
                other.address, recipient.address,
                usdc(10), "p2", 1n, expiredAt
            );
            await tipJar.connect(other).tip(
                recipient.address, usdc(10), "p2", 1n, expiredAt, sig2
            );

            // Both succeeded
            expect(await tipJar.isNonceUsed(tipper.address, 1n)).to.be.true;
            expect(await tipJar.isNonceUsed(other.address, 1n)).to.be.true;
        });
    });
});
