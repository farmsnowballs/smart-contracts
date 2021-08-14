const { expect } = require("chai")
const { ethers, run } = require("hardhat")
const { BigNumber } = ethers

describe("TokenFeeCollector", function() {

    before(async () => {
        await run("compile")
    })

    let owner
    let account1
    let account2
    let tokenFeeCollector
    let WAVAX

    beforeEach(async () => {
        let accounts = await ethers.getSigners()
        owner = accounts[0]
        account1 = accounts[1]
        account2 = accounts[2]
        const tokenFeeCollectorFactory = await ethers.getContractFactory("TokenFeeCollector")
        tokenFeeCollector = await tokenFeeCollectorFactory.deploy()
        await tokenFeeCollector.deployed()
        WAVAX = await ethers.getContractAt("IWAVAX", "0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7")
        //makes sure owner has enough WAVAX balance
        if ((await WAVAX.balanceOf(owner.address)).lt("1000000000000000000000")) {
            WAVAX.connect(owner).deposit({
                value: BigNumber.from("1000000000000000000000")
                       .sub(await WAVAX.balanceOf(owner.address))
            })
        }

        //makes sure other accounts are clean
        if ((await WAVAX.balanceOf(account1.address)).gt(0)) {
            await WAVAX.connect(account1).withdraw((await WAVAX.balanceOf(account1.address)))
        }
        if ((await WAVAX.balanceOf(account2.address)).gt(0)) {
            await WAVAX.connect(account2).withdraw((await WAVAX.balanceOf(account2.address)))
        }
    })

     
    it('Can deploy', async () => {
        expect(await tokenFeeCollector.owner()).to.equal(owner.address)
    })

    it('Owner can register token', async () => {
        const tenPercent = 100000000 * 10/100;
        await tokenFeeCollector.registerToken(WAVAX.address, account1.address, tenPercent);
        let [payeeAddress, sharePercent] = await tokenFeeCollector.viewPayee(WAVAX.address, 0)
        expect(payeeAddress).to.equal(account1.address)
        expect(sharePercent).to.equal(tenPercent)
    })

    it('Owner can add Payee', async () => {
        const tenPercent = 100000000 * 10/100;
        await tokenFeeCollector.registerToken(WAVAX.address, account1.address, tenPercent)
        await tokenFeeCollector.addPayee(WAVAX.address, account2.address, tenPercent+1)
        let [payeeAddress, sharePercent] = await tokenFeeCollector.viewPayee(WAVAX.address, 0)
        expect(payeeAddress).to.equal(account1.address)
        expect(sharePercent).to.equal(tenPercent)
        let [payeeAddress2, sharePercent2] = await tokenFeeCollector.viewPayee(WAVAX.address, 1)
        expect(payeeAddress2).to.equal(account2.address)
        expect(sharePercent2).to.equal(tenPercent+1)
    })

    it('Owner can edit Payee', async () => {
        const tenPercent = 100000000 * 10/100;
        await tokenFeeCollector.registerToken(WAVAX.address, account1.address, tenPercent)
        await tokenFeeCollector.addPayee(WAVAX.address, account2.address, tenPercent+1)
        await tokenFeeCollector.editPayee(WAVAX.address, account1.address, tenPercent-1)
        await tokenFeeCollector.editPayee(WAVAX.address, account2.address, tenPercent+10)
        let [payeeAddress, sharePercent] = await tokenFeeCollector.viewPayee(WAVAX.address, 0)
        expect(payeeAddress).to.equal(account1.address)
        expect(sharePercent).to.equal(tenPercent-1)
        
        let [payeeAddress2, sharePercent2] = await tokenFeeCollector.viewPayee(WAVAX.address, 1)
        expect(payeeAddress2).to.equal(account2.address)
        expect(sharePercent2).to.equal(tenPercent+10)
    })

    it('Owner can remove Payee', async () => {
        const tenPercent = 100000000 * 10/100;
        await tokenFeeCollector.registerToken(WAVAX.address, account1.address, tenPercent)
        await tokenFeeCollector.addPayee(WAVAX.address, account2.address, tenPercent)

        let [payeeAddress, sharePercent] = await tokenFeeCollector.viewPayee(WAVAX.address, 0)
        expect(payeeAddress).to.equal(account1.address)
        expect(sharePercent).to.equal(tenPercent)
        let [payeeAddress2, sharePercent2] = await tokenFeeCollector.viewPayee(WAVAX.address, 1)
        expect(payeeAddress2).to.equal(account2.address)
        expect(sharePercent2).to.equal(tenPercent)

        await tokenFeeCollector.removePayee(WAVAX.address, account1.address)
        let [payeeAddress3, sharePercent3] = await tokenFeeCollector.viewPayee(WAVAX.address, 0)
        expect(payeeAddress3).to.equal(account2.address)
        expect(sharePercent3).to.equal(tenPercent)
        await expect(tokenFeeCollector.viewPayee(WAVAX.address, 1)).to.be.reverted
    })
    
    it('Others cant register token', async () => {
        await expect(tokenFeeCollector.connect(account1).registerToken(WAVAX.address, account1.address, 1)).to.be.reverted;
    })

    it('Others cant add Payee', async () => {
        const tenPercent = 100000000 * 10/100;
        await tokenFeeCollector.registerToken(WAVAX.address, account1.address, tenPercent)
        await expect(tokenFeeCollector.connect(account1).addPayee(WAVAX.address, account2.address, tenPercent+1)).to.be.reverted
    })

    it('Others cant edit Payee', async () => {
        const tenPercent = 100000000 * 10/100;
        await tokenFeeCollector.registerToken(WAVAX.address, account1.address, tenPercent)
        await tokenFeeCollector.addPayee(WAVAX.address, account2.address, tenPercent+1)
        await expect(tokenFeeCollector.connect(account1).editPayee(WAVAX.address, account1.address, tenPercent-1)).to.be.reverted
    })

    it('Others cant remove Payee', async () => {
        const tenPercent = 100000000 * 10/100;
        await tokenFeeCollector.registerToken(WAVAX.address, account1.address, tenPercent)
        await tokenFeeCollector.addPayee(WAVAX.address, account2.address, tenPercent)
        await expect(tokenFeeCollector.connect(account1).removePayee(WAVAX.address, account1.address)).to.be.reverted
    })

    it('Payee can view balance', async () => {
        const maxBips = 100000000
        const tenPercent = maxBips * 10/100
        const eightyPercent = BigNumber.from(8).mul(tenPercent)
        await tokenFeeCollector.registerToken(WAVAX.address, owner.address, eightyPercent)
        await tokenFeeCollector.addPayee(WAVAX.address, account1.address, tenPercent)
        await tokenFeeCollector.addPayee(WAVAX.address, account2.address, tenPercent)
        const payment = 1000000000000
        await WAVAX.transfer(tokenFeeCollector.address, payment)

        let [sharePercent, balance] = await tokenFeeCollector.connect(owner).viewBalance(WAVAX.address)
        expect(balance).to.equal(payment*eightyPercent/maxBips)
        expect(sharePercent).to.equal(8*tenPercent)
        let [sharePercent1, balance1] = await tokenFeeCollector.connect(account1).viewBalance(WAVAX.address)
        expect(balance1).to.equal(payment*tenPercent/maxBips)
        expect(sharePercent1).to.equal(tenPercent)
        let [sharePercent2, balance2] = await tokenFeeCollector.connect(account2).viewBalance(WAVAX.address)
        expect(balance2).to.equal(payment*tenPercent/maxBips)
        expect(sharePercent2).to.equal(tenPercent)
    })

    it('Payee can collect fee', async () => {
        const maxBips = 100000000
        const tenPercent = maxBips * 10/100
        const eightyPercent = BigNumber.from(8).mul(tenPercent)
        await tokenFeeCollector.registerToken(WAVAX.address, owner.address, eightyPercent)
        await tokenFeeCollector.addPayee(WAVAX.address, account1.address, tenPercent)
        await tokenFeeCollector.addPayee(WAVAX.address, account2.address, tenPercent)

        const payment = 1000000000000
        await WAVAX.transfer(tokenFeeCollector.address, payment)
        let ownerWAVAXBalance = await WAVAX.balanceOf(owner.address)
        await tokenFeeCollector.connect(account1).collectFee(WAVAX.address)

        expect(await WAVAX.balanceOf(account1.address)).to.equal(payment*tenPercent/maxBips)
        expect(await WAVAX.balanceOf(account2.address)).to.equal(payment*tenPercent/maxBips)
        expect(await WAVAX.balanceOf(owner.address)).to.equal(ownerWAVAXBalance.add(payment*eightyPercent/maxBips))
        expect(await WAVAX.balanceOf(tokenFeeCollector.address)).to.equal(0)
    })

    it('Owner can recover funds', async () => {
        const maxBips = 100000000
        const tenPercent = maxBips * 10/100
        const eightyPercent = BigNumber.from(8).mul(tenPercent)
        await tokenFeeCollector.registerToken(WAVAX.address, owner.address, eightyPercent)
        await tokenFeeCollector.addPayee(WAVAX.address, account1.address, tenPercent)
        await tokenFeeCollector.addPayee(WAVAX.address, account2.address, tenPercent)
        
        let ownerWAVAXBalance = await WAVAX.balanceOf(owner.address)
        const payment = 1000000000000
        await WAVAX.transfer(tokenFeeCollector.address, payment)
        await tokenFeeCollector.recoverToken(WAVAX.address)

        expect(await WAVAX.balanceOf(owner.address)).to.equal(ownerWAVAXBalance)
    })
})
