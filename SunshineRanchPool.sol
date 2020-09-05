package com.dos.doswallet.service;

import com.baomidou.mybatisplus.core.conditions.query.LambdaQueryWrapper;
import com.dos.doswallet.blakehash.Base58;
import com.dos.doswallet.response.ResultCode;
import com.dos.doswallet.response.exception.CustomException;
import com.dos.doswallet.rpc.DosNodeApi;
import com.dos.doswallet.rpc.DosWalletApi;
import com.dos.doswallet.utils.RedisUtil;
import com.dos.doswallet.vo.entity.MasterWallet;
import com.dos.doswallet.vo.entity.URecharge;
import com.dos.doswallet.vo.entity.UWithdraw;
import com.dos.doswallet.vo.service.IMasterWalletService;
import com.dos.doswallet.vo.service.IURechargeService;
import com.dos.doswallet.vo.service.IUWithdrawService;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;
import org.springframework.util.LinkedMultiValueMap;
import org.springframework.util.MultiValueMap;
import org.springframework.web.client.RestClientException;
import org.springframework.web.client.RestTemplate;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.math.RoundingMode;
import java.util.*;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

@Service
@Slf4j
public class WalletService {

    byte[] testNetVersion = new byte[]{(byte) 0x0E, (byte) 0xfb};
    byte[] mainNetVersion = new byte[]{(byte) 0x0E, (byte) 0x6B};
    static Pattern P_INPUT = Pattern.compile("^(\\w{8})(0{24}(\\w{40}))(0{24}(\\w{40})){0,1}(\\w{64})$");


    private static final String dos_send = "d0679d34";

    private final WalletRedisService redisSvc;

    private final DosNodeApi nodeRpc;
    private final DosWalletApi walletRpc;

    private final IMasterWalletService masterWalletService;
    private final IURechargeService rechargeService;
    private final IUWithdrawService withdrawService;

    private final RestTemplate restTemplate;


    @Value("${rest.server.recharge}")
    private String rechargeUrl;
    @Autowired
    private RedisUtil redisUtil;

    @Autowired
    public WalletService(WalletRedisService redisSvc, DosNodeApi nodeRpc, DosWalletApi walletRpc, IMasterWalletService masterWalletService, IURechargeService rechargeService, IUWithdrawService withdrawService, RestTemplate restTemplate) {
        this.redisSvc = redisSvc;
        this.nodeRpc = nodeRpc;
        this.walletRpc = walletRpc;
        this.masterWalletService = masterWalletService;
        this.rechargeService = rechargeService;
        this.withdrawService = withdrawService;


        this.restTemplate = restTemplate;
    }

    public void scanBlockForDeposit() {


        LambdaQueryWrapper<MasterWallet> queryWrapper = new LambdaQueryWrapper<>();
        queryWrapper.eq(MasterWallet::getType, "C");
        List<MasterWallet> coldWallets = masterWalletService.list(queryWrapper);

        long nextBlock = redisSvc.getNextBlock();
        long blockNum = nodeRpc.getsideblockcount();
        if (nextBlock == 0) {
            nextBlock = blockNum - 1;
        }
        while (nextBlock < blockNum) {
            log.info("查询位于区块高度{}的交易", ++nextBlock);
            try {
                String hash = nodeRpc.getsideblockhash(nextBlock);
                DosNodeApi.SideBlock blockTx = nodeRpc.getsideblock(hash);
                blockTx.getTx().forEach(txId -> {
                    DosNodeApi.RawTransaction rawTransaction = nodeRpc.getsiderawtransaction(txId, 1);
                    rawTransaction.getVout().forEach(voutBean -> {
                        coldWallets.forEach(coldWallet -> {
                            if (voutBean.getScriptPubKey().getAddresses().contains(coldWallet.getContract())) {
                                String[] asm = voutBean.getScriptPubKey().getAsm().split(" ");
                                if (asm.length == 5 && asm[asm.length - 1].equals("OP_CALL")) {
                                    String data = asm[asm.length - 2];
                                    Matcher m = P_INPUT.matcher(data);
                                    if (m.find()) {
                                        String method = m.group(1);
                                        String address = m.group(3);
                                        String hexAmount = m.group(6);

                                        //转账的来源地址
                                        String to = Base58.encodeChecked(mainNetVersion, hexToBytes(address));
                                        if (method.equals(dos_send)) {
                                            if (to.equals(coldWallet.getAddress())) {
                                                List<DosNodeApi.RawTransaction.VinBean> vinBeans = rawTransaction.getVin();
                                                if (vinBeans.size() > 0) {
                                                    String fromHex = vinBeans.get(0).getTxid().substring(0, 40);
                                                    String from = null;
                                                    List<String> hexArr = new ArrayList<>();
                                                    char[] hex = fromHex.toCharArray();
                                                    for (int i = 0; i < fromHex.toCharArray().length; i += 2) {
                                                        hexArr.add(String.valueOf(hex[i]) + hex[i + 1]);
                                                    }
                                                    Collections.reverse(hexArr);
                                                    StringBuilder stringBuilder = new StringBuilder();
                                                    for (String s : hexArr) {
                                                        stringBuilder.append(s);
                                                    }
                                                    from = Base58.encodeChecked(mainNetVersion, hexToBytes(stringBuilder.toString()));

                                                    BigDecimal amount = toDecimal(new BigInteger(hexAmount, 16), coldWallet.getDecimals());
                                                    deposit(coldWallet.getSymbol(), from, amount, txId, 1);
                                                    log.info("收到入币：{}|{}|{}|{}", amount, coldWallet.getSymbol(), from, txId);
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        });
                    });
                });
            } catch (Exception e) {
                e.printStackTrace();
            }
            redisSvc.setNextBlock(nextBlock);
        }
    }


    /**
     * 存款
     *
     * @param symbol  币种 FT，TRX
     * @param address
     * @param amount
     * @param trxId   交易唯一标识，必存
     */
    public void deposit(String symbol, String address, BigDecimal amount, String trxId, final int repeat) {

        LambdaQueryWrapper<URecharge> queryWrapper = new LambdaQueryWrapper<>();
        queryWrapper.eq(URecharge::getHash, trxId);
        URecharge uRecharge = rechargeService.getOne(queryWrapper);
        if (uRecharge == null) {
            uRecharge = new URecharge();
            uRecharge.setAmount(amount);
            uRecharge.setSymbol(symbol);
            uRecharge.setHash(trxId);
            uRecharge.setPayee(address);
            uRecharge.setStatus(0);
            uRecharge.setCreateTime(System.currentTimeMillis());
            rechargeService.save(uRecharge);
        } else if (uRecharge.getStatus() == 1) {
            return;
        }
        MultiValueMap<String, Object> params = new LinkedMultiValueMap<>();
        params.set("address", address);
        params.set("paytime", System.currentTimeMillis());
        params.set("paynumber", amount);
        params.set("trxid", trxId);
        params.set("symbol", symbol);
        String result = null;
        try {
            result = restTemplate.postForObject(rechargeUrl, params, String.class);
            ObjectMapper objectMapper = new ObjectMapper();
            JsonNode jsonNode = objectMapper.readTree(result);
            if (jsonNode.has("code")) {
                if (jsonNode.get("code").asInt() == 200) {
                    log.info("充值成功：HASH：{}", trxId);
                    uRecharge.setStatus(1);
                    rechargeService.saveOrUpdate(uRecharge);
                    return;
                }
            }
        } catch (RestClientException | JsonProcessingException e) {
//            e.printStackTrace();
        }


        if (repeat > 8) {
            log.info("{}:{}-充值失败：{}", address, amount.toString(), result);

            uRecharge.setStatus(2);
            rechargeService.saveOrUpdate(uRecharge);
            return;
        }

        log.info("{}:{}-充值失败：{}分钟后重试,{}", address, amount.toString(), repeat, result);
        Timer timer = new Timer();
        timer.schedule(new TimerTask() {
            int rep = repeat;

            public void run() {
                deposit(symbol, address, amount, trxId, ++rep);
                this.cancel();
            }
        }, 60000 * repeat);// 这里百毫秒
    }

    public JsonNode getMasterWalletBalance(String symbol) {
        LambdaQueryWrapper<MasterWallet> queryWrapper = new LambdaQueryWrapper<>();
        queryWrapper.eq(MasterWallet::getSymbol, symbol);
        List<MasterWallet> hotWallet = masterWalletService.list(queryWrapper);
        ObjectMapper objectMapper = new ObjectMapper();

        ObjectNode objectNode = objectMapper.createObjectNode();
        ArrayNode arrayNode = objectMapper.createArrayNode();

        for (MasterWallet masterWallet : hotWallet) {

            BigInteger balance = nodeRpc.gettoken(masterWallet.getContract(), masterWallet.getAddress());
            ObjectNode itemNode = objectMapper.createObjectNode();
            itemNode.put("balance", toDecimal(balance, masterWallet.getDecimals()));
            itemNode.put("type", masterWallet.getType());
            itemNode.put("symbol", masterWallet.getSymbol());
            arrayNode.add(itemNode);
        }

        objectNode.putPOJO("wallets", arrayNode);
        return objectNode;
    }


    public String transfer(String symbol, String toAddress, BigDecimal value) {

        if (BigDecimal.valueOf(500).compareTo(value) < 0) {
            throw new CustomException(ResultCode.WITHDRAW_DAY_LIMIT);
        }

        synchronized (this) {
            try {
                if (redisUtil.hasKey("DOS_TRANSFER_INTERVAL" + "_" + symbol + "_" + toAddress)) {
                    throw new CustomException(ResultCode.WITHDRAW_TOO_OFTEN);
                }
                redisUtil.set("DOS_TRANSFER_INTERVAL" + "_" + symbol + "_" + toAddress, value, 10);
            } catch (Exception e) {
                throw new CustomException(ResultCode.WITHDRAW_TOO_OFTEN);
            }
        }
        LambdaQueryWrapper<MasterWallet> queryWrapper = new LambdaQueryWrapper<>();
        queryWrapper.eq(MasterWallet::getSymbol, symbol);
        queryWrapper.eq(MasterWallet::getType, "H");
        MasterWallet hotWallet = masterWalletService.getOne(queryWrapper, false);

        if (hotWallet == null) {
            throw new CustomException(ResultCode.PARAM_IS_INVALID);
        }
        BigInteger hotBalance = nodeRpc.gettoken(hotWallet.getContract(), hotWallet.getAddress());
        if (hotBalance.compareTo(toInteger(value, hotWallet.getDecimals())) < 0) {
            throw new CustomException(ResultCode.BALANCE_NOT_ENOUGH);
        }

        Object[] params = new Object[]{toAddress, toInteger(value, hotWallet.getDecimals()).longValue()};
        ObjectMapper objectMapper = new ObjectMapper();
        try {
            String param = objectMapper.writeValueAsString(params);
            String hash = walletRpc.action(hotWallet.getAccount(), hotWallet.getContract(), "send", param);
            UWithdraw uWithdraw = new UWithdraw();
            uWithdraw.setAmount(value);
            uWithdraw.setCreateTime(System.currentTimeMillis());
            uWithdraw.setSymbol(symbol);
            uWithdraw.setToAddress(toAddress);
            uWithdraw.setHash(hash);
            withdrawService.save(uWithdraw);

            log.info("热钱包出币：{}|{}|{}|{}|{}", toAddress, symbol, value.toString(), toDecimal(hotBalance, hotWallet.getDecimals()).subtract(value).toString(), hash);

            redisUtil.set("DOS_TRANSFER_INTERVAL" + "_" + symbol + "_" + toAddress, value, 60 * 60 * 24);
            return hash;
        } catch (Exception e) {
            throw new CustomException(ResultCode.FAIL.getCode(), e.getMessage());
        }

    }

    public static byte[] hexToBytes(String input) {
        String cleanInput = input.trim();

        int len = cleanInput.length();

        if (len == 0) {
            return new byte[]{};
        }

        byte[] data;
        int startIdx;
        if (len % 2 != 0) {
            data = new byte[(len / 2) + 1];
            data[0] = (byte) Character.digit(cleanInput.charAt(0), 16);
            startIdx = 1;
        } else {
            data = new byte[len / 2];
            startIdx = 0;
        }

        for (int i = startIdx; i < len; i += 2) {
            data[(i + 1) / 2] = (byte) ((Character.digit(cleanInput.charAt(i), 16) << 4)
                    + Character.digit(cleanInput.charAt(i + 1), 16));
        }
        return data;
    }


    static BigDecimal toDecimal(BigInteger i, int decimal) {
        return new BigDecimal(i).divide(BigDecimal.valueOf(Math.pow(10, decimal)), decimal, RoundingMode.FLOOR);
    }

    static BigInteger toInteger(BigDecimal i, int decimal) {

        return i.multiply(BigDecimal.valueOf(Math.pow(10, decimal))).toBigInteger();
    }

}

